# NOOP — System Architecture

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and 5.0). It talks
directly to the strap over Bluetooth Low Energy, stores everything on-device in SQLite (GRDB on Mac/iOS, Room on Android), and computes
recovery, strain, HRV, and sleep locally. There is no WHOOP cloud, no account —
the app interoperates with **your own device and your own data**. It can also import data you already
own: WHOOP CSV exports and Apple Health exports.

> **Not affiliated with WHOOP.** NOOP is an independent, interoperability project built on
> community reverse-engineering of the strap's Bluetooth protocol. It is **not a medical device**
> and produces **approximate** physiological estimates that must not be used for diagnosis or
> treatment. See [`DISCLAIMER.md`](../DISCLAIMER.md) and [`ATTRIBUTION.md`](../ATTRIBUTION.md).

---

## 1. The big picture

The system is a one-directional pipeline. Bytes arrive from the strap (or from an import file), get
decoded into typed rows, land durably in SQLite, are read back through a thin repository, are turned
into daily metrics by pure analytics functions, and finally render in SwiftUI. Nothing is ever sent
off-device.

```
                          ┌─────────────────────────────────────────────────────────┐
   WHOOP strap (4.0/5.0)  │                     NOOP (on-device)                     │
   ────────────────────   │                                                          │
        BLE GATT           │   CoreBluetooth          WhoopProtocol (pure decode)    │
   ┌──────────────┐  notify│  ┌────────────┐  bytes  ┌──────────────────────────┐    │
   │ custom svc   ├────────┼─▶│ BLEManager │────────▶│ Reassembler              │    │
   │ 6108…/fd4b…  │  write │  │ (CoreBT    │  frames │  → parseFrame            │    │
   │ HR 0x2A37    │◀───────┼──│  delegate) │         │  → extract[Historical]…  │    │
   │ batt 0x2A19  │  cmds  │  └─────┬──────┘         └────────────┬─────────────┘    │
   └──────────────┘        │        │                             │ Streams          │
                           │        │ complete frame              ▼                  │
                           │        ▼                  ┌──────────────────────┐      │
                           │  ┌───────────┐  live      │  WhoopStore (actor)  │      │
                           │  │FrameRouter│──events────▶│  GRDB / SQLite       │      │
                           │  │ LiveState │  HR/RR/UI  │  decoded streams +   │      │
                           │  └───────────┘            │  metric caches +     │      │
                           │        │                  │  raw outbox          │      │
                           │   live │ ┌─────────┐ hist └─────────┬────────────┘      │
                           │        └▶│Collector│ ┌──────────┐   │ reads             │
                           │          └─────────┘ │Backfiller│   ▼                   │
                           │   imports            └──────────┘ ┌────────────┐        │
   files ──────────────────┼─▶ StrandImport ──────────────────▶│ Repository │        │
   export.zip / *.csv      │   (CSV + Apple Health)            └─────┬──────┘        │
                           │                                         ▼               │
                           │                      StrandAnalytics ──▶ SwiftUI screens│
                           │                      (HRV/recovery/    (StrandDesign)   │
                           │                       strain/sleep)                     │
                           └─────────────────────────────────────────────────────────┘
```

The same `WhoopStore` SQLite file is the single convergence point for three independent producers:
the **live** BLE path, the **historical** BLE offload path, and the **import** path. All readers go
through `Repository`.

---

## 2. Repository layout

```
Strand/                         macOS SwiftUI app target (the reference implementation)
├── App/                        Composition root + window/scene
│   ├── StrandApp.swift         @main App scene; owns AppModel, wires environment objects
│   ├── AppModel.swift          @MainActor root state — owns BLE, Repository, profiles
│   ├── RootView.swift          NavigationSplitView shell + NavItem routing
│   └── ContentView.swift
├── BLE/                        CoreBluetooth + the live/decode seam
│   ├── BLEManager.swift        CBCentral/CBPeripheral delegate, scan→bond→stream
│   ├── FrameRouter.swift       pure decode→LiveState router (no CoreBluetooth)
│   ├── LiveState.swift         @MainActor observable connection/biometric snapshot
│   ├── Commands.swift          WhoopCommand enum (command bytes + frame builders)
│   ├── StandardHeartRate.swift 0x2A37 BLE-standard HR/RR parser (pure)
│   ├── BackfillPolicy.swift    rate-limiter for historical offload triggers
│   └── StuckStrapDetector.swift safety-net liveness watchdog
├── Collect/                    Persistence orchestration (BLE → store)
│   ├── Collector.swift         buffers live frames → decoded-first persistence
│   ├── Backfiller.swift        historical-offload state machine (safe-trim)
│   ├── ClockCorrelation.swift  device-epoch ↔ wall-clock correlation (pure)
│   ├── ClockPolicy.swift       when to (re)issue SET_CLOCK
│   ├── StorePaths.swift        on-disk SQLite location (App Support/OpenWhoop)
│   ├── PrunePolicy.swift       raw-outbox retention (24h / 50MB)
│   └── RawCaptureWindow.swift  bounded on-demand raw-capture window
├── Data/                       Read model + import glue
│   ├── Repository.swift        @MainActor read model over WhoopStore
│   ├── WhoopImporter.swift     CSV result → store rows
│   ├── AppleHealthImport.swift Apple Health result → store rows
│   ├── Profile.swift           user profile (age/sex/body/HRmax)
│   └── BehaviorStore.swift     toggles for automations/coaching
├── Screens/                    SwiftUI feature screens (Today, Live, Sleep, Trends…)
├── MenuBar/                    glanceable menu-bar extra
└── System/                     macOS integrations (lock screen, Shortcuts)

Packages/                       Cross-platform Swift packages (iOS 16+ / macOS 13+)
├── WhoopProtocol/              BLE frame parsing, CRC, command/event/packet decode
├── WhoopStore/                 GRDB/SQLite persistence (actor)
├── StrandAnalytics/            HRV/recovery/strain/sleep/correlation math
├── StrandImport/               WHOOP CSV + Apple Health importers
└── StrandDesign/               SwiftUI design system (palette, components, charts)

Tools/Backfill/                 CLI offload/replay tool
```

The app target (`Strand/`) is the **macOS reference implementation**. The same five packages back the
**iOS** app (`StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` — **build-from-source only**, no
App Store/TestFlight; see [`IOS.md`](./IOS.md)) and the **Android** app (`android/`, Room/Kotlin). The
packages already declare `.iOS(.v16)` and `.macOS(.v13)` and keep all UI-framework code behind
`#if canImport(UIKit)` / `#if canImport(AppKit)` guards so the cores port unchanged.

---

## 3. Package responsibilities and boundaries

Each package has a narrow contract. The dependency graph is acyclic and the leaf packages are
**platform-pure** (no CoreBluetooth, no UIKit/AppKit) so they run in CLI tools and tests:

```
StrandDesign        (no deps — pure SwiftUI)

WhoopProtocol       (no deps)
   ▲
   │
WhoopStore ─────────▶ GRDB.swift
   ▲
   │
StrandAnalytics ────▶ WhoopProtocol + WhoopStore
StrandImport ───────▶ WhoopProtocol + WhoopStore + ZIPFoundation
```

| Package | Responsibility | Key types / functions | Notable boundary |
|---|---|---|---|
| **WhoopProtocol** | The reverse-engineering core: turn raw BLE bytes into typed rows. Framing, CRC, fragment reassembly, schema-driven field decode, stream extraction, historical-chunk classification. | `Reassembler`, `verifyFrame`, `parseFrame` → `ParsedFrame`, `extractStreams`, `extractHistoricalStreams`, `classifyHistoricalMeta`, `Streams`, `DeviceFamily`, `crc8`/`crc16Modbus`/`crc32` | **No CoreBluetooth.** Exposes GATT UUIDs as `String`; the app wraps them in `CBUUID`. |
| **WhoopStore** | Durable on-device persistence built on GRDB/SQLite. Migrations, decoded streams, metric caches, generic metric series, raw outbox, cursors. | `actor WhoopStore`, `makeMigrator()`, `insert(_:deviceId:)`, `dailyMetrics`, `sleepSessions`, `metricSeries`, `pruneRaw`, `ClockRef`, `RawBatchMeta` | An **`actor`** — all writes/reads run off the main thread on its serial executor. |
| **StrandAnalytics** | All physiological math, as pure functions over inputs. HRV, recovery, strain, sleep staging, workout detection, baselines, HR zones, correlation/comparison. | `AnalyticsEngine.analyzeDay(...)` → `DayResult`, `HRVAnalyzer`, `RecoveryScorer`, `StrainScorer`, `SleepStager`, `WorkoutDetector`, `Baselines`, `CorrelationEngine` | **Pure** — never touches the database. Produces `DailyMetric`/`CachedSleepSession` shapes for the store. |
| **StrandImport** | Parse data the user already owns: WHOOP CSV exports and Apple Health exports (`export.xml`, streaming). | `ImportCoordinator.detectAndImport`, `WhoopExportImporter`, `AppleHealthImporter`, `AppleHealthAggregator` | **Parsing only** — returns normalized model arrays; the app maps them into the store. |
| **StrandDesign** | The SwiftUI design system: palette, typography, motion, charts, components. | `StrandPalette`, `StrandCard`, `RecoveryRing`, `StrainGauge`, `Hypnogram`, `TrendChart`, `Sparkline`, `YearHeatStrip` | No data or protocol deps — pure presentation. |

### Multi-generation protocol support

`WhoopProtocol` supports both strap generations through `DeviceFamily`:

- **`.whoop4`** — the original reverse-engineered protocol: `0xAA` SOF, `u16 LE` length, **CRC8**
  (poly `0x07`) header check, `CRC32` (zlib) payload trailer.
- **`.whoop5`** — the newer "puffin" transport: a format byte, **CRC16-Modbus** header check, and a
  set of packet types (e.g. `PUFFIN_COMMAND_RESPONSE` = 38, `PUFFIN_METADATA` = 56) that
  `canonicalTypeName(_:schema:)` aliases onto the 4.0 base names so they decode with the same logic.

`verifyFrame(_:family:)` and the `DeviceFamily` UUID/CLIENT_HELLO accessors are the single switch
points between generations; everything downstream of `parseFrame` is generation-agnostic.

---

## 4. The actor / concurrency model

Concurrency is deliberately split between two isolation domains plus a serial drain:

| Component | Isolation | Why |
|---|---|---|
| `WhoopStore` | **`actor`** | GRDB's `DatabaseQueue` calls block; the actor moves that blocking off the main thread onto its own serial executor. `DatabaseQueue` (not `DatabasePool`) is kept on purpose — the actor provides serialization. |
| `AppModel`, `LiveState`, `Repository`, `BLEManager`, `FrameRouter`, `Collector`, `Backfiller` | **`@MainActor`** | These observe/mutate published UI state. CoreBluetooth's central is created on `queue: .main`, so delegate callbacks already arrive on the main actor — no hopping needed to update `LiveState`. |
| Historical frame drain | **serial Task queue** | `BLEManager.routeBackfillFrame` appends frames synchronously (delegate order) and a single drain `Task` awaits `Backfiller.ingest` one frame at a time, so `HISTORY_START → data → HISTORY_END` chunk assembly can never be reordered. |

The key invariant: **frames are buffered synchronously in delegate-callback order**, and only the
slow work (decode + `await store.insert`) crosses into the store actor. `Collector.flush()` and
`Backfiller.finishChunk()` both *snapshot-and-clear* their buffer before the first `await`, so
concurrent ingests accumulate cleanly into the next batch.

Two SQLite handles are open simultaneously — one inside `BLEManager`'s `Collector`/`Backfiller`, one
inside `Repository`. This is safe because `WhoopStore` enables **WAL journal mode** and a **5-second
busy timeout** (`PRAGMA journal_mode = WAL`, `config.busyMode = .timeout(5)`), so the writer and the
reader never deadlock on contention.

---

## 5. Live path vs. historical path

The two BLE data paths diverge at one branch in `BLEManager.peripheral(_:didUpdateValueFor:)`. After
the `Reassembler` yields a complete frame, `FrameRouter.handle(frame:)` always runs (it drives the
live UI state), and then:

```swift
if backfilling {
    if BLEManager.isOffloadFrame(frame) {   // types 47/48/49/50 only
        armBackfillTimeout()
        routeBackfillFrame(frame)           // serial drain → Backfiller
    }                                       // live type-40/43 flood is dropped during offload
} else {
    collector?.ingest(frame)                // live → Collector
}
```

### Live path (real-time)

1. **CoreBluetooth notify** on the data/cmd/event characteristics, or on standard HR `0x2A37`.
2. **`Reassembler.feed`** accumulates BLE fragments into complete `0xAA…CRC32` frames.
3. **`FrameRouter.handle`** runs `parseFrame`, rejects bad-CRC frames, and updates `LiveState`
   (`heartRate`, `rr`, `lastEvent`, `worn`, …). `EVENT` packets fire physical-input hooks
   (double-tap, wrist on/off) and a rate-limited catch-up sync trigger.
4. **`Collector.ingest`** buffers the frame. Once a `ClockRef` exists (from `GET_CLOCK`
   correlation), it flushes on cadence (`maxFrames: 64` or `maxInterval: 30s`):
   `parseFrame → extractStreams(clockRef) → store.insert` (**decoded first, durable**) →
   optionally `enqueueRawBatch` (raw, transient).
5. Standard `0x2A37` HR/RR is recorded **continuously and independently** via
   `Collector.ingestStandardHR` — it carries a wall-clock timestamp so it needs no clock
   correlation and keeps recording regardless of which screen is open.

Live `REALTIME_DATA` (type 40) timestamps are a **device monotonic epoch**; `extractStreams` maps
them to wall time with the linear `(device, wall)` offset captured at connect by
`ClockCorrelation`/`GET_CLOCK`.

### Historical path (offload / backfill)

The strap holds a ~14-day on-device biometric store. NOOP re-offloads it the way the official client
syncs — once per connect and then every `backfillIntervalSeconds` (900s) while connected+bonded — so
the periodic **type-47 historical offload is the primary metric source**, not the live stream.

1. `requestSync(_:)` gates every kick on connection state **and** `BackfillPolicy` (the rate
   limiter, persisted across relaunch). On a go it calls `beginBackfill()`, which sends
   `SEND_HISTORICAL_DATA` and arms an idle watchdog.
2. The strap streams `HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE`.
3. `Backfiller.ingest` is a state machine driven by `classifyHistoricalMeta`. On each `HISTORY_END`
   it commits one chunk with a strict **local safe-trim invariant**:

   ```
   decode chunk  →  await store.insert (decoded durable)
                 →  await store.enqueueRawBatch (only if research toggle on)
                 →  await store.setCursor("strap_trim", …)
                 →  ackTrim (.withResponse confirmed ack to strap)
   ```

   A chunk is forgotten by the strap **only after** decoded data is locally durable and the ack is
   link-layer confirmed. If the watchdog fires (strap went silent), nothing is acked and the durable
   `strap_trim` cursor lets the next session resume exactly where it left off.

Type-47 records carry their **own real-unix timestamps**, so the historical path does *not* depend on
`GET_CLOCK`; if the clock correlation hasn't landed yet, `Backfiller` falls back to an identity
`ClockRef` and the offset math becomes a no-op.

### Why they differ

| Aspect | Live path | Historical path |
|---|---|---|
| Producer | `Collector` | `Backfiller` |
| Trigger | Continuous notify | `SEND_HISTORICAL_DATA`, rate-limited |
| Frame types | 40/43 (REALTIME) + 0x2A37 | 47/48/49/50 (HISTORICAL/EVENT/META/LOGS) |
| Timestamp source | Device epoch → wall via `ClockRef` | Real unix in the record |
| Durability unit | Cadence flush (64 frames / 30s) | One `HISTORY_END` chunk, trim-acked |
| Decode fn | `extractStreams` | `extractHistoricalStreams` |
| Role | Live HR/UI + opt-in detail | **Primary** metric source |

---

## 6. The BLE connection lifecycle

`BLEManager` is the only CoreBluetooth surface. The connection handshake runs **exactly once per
connection** (guarded by `connectHandshakeDone`, because `didWriteValueFor` re-fires on every
confirmed write):

```
scan(customService) ─▶ didDiscover ─▶ connect ─▶ didDiscoverServices
   ─▶ discover characteristics ─▶ BOND (one confirmed GET_BATTERY_LEVEL write to …0002)
   ─▶ subscribe notify on cmd/event/data + 0x2A37 + 0x2A19
   ─▶ didWriteValueFor (bond ack) ─┬─ HELLO → SET_CLOCK → GET_CLOCK
                                   ├─ stop type-43 realtime flood, GET_DATA_RANGE
                                   ├─ requestSync(.connect)  (deferred ~1.5s)
                                   ├─ startBackfillTimer()   (re-offload every 900s)
                                   └─ startKeepAlive()       (re-arm realtime, poll battery, watchdog)
```

Supporting machinery, all on the main run loop:

- **Keep-alive (30s):** re-arms the realtime stream if wanted, polls battery, and — if **no
  notification has arrived for >120s** — bounces the link; the auto-rescan on disconnect re-bonds and
  resumes streaming.
- **Stuck-strap watchdog:** after each offload, `StuckStrapDetector` compares the strap's newest
  record (`GET_DATA_RANGE`) against NOOP's data frontier (`latestHRSampleTs`). Strap-ahead **and**
  frontier-frozen ⇒ a reboot hint banner; off-wrist / caught-up is *not* flagged.
- **Auto-reconnect:** an unintentional disconnect flushes the `Collector` and rescans after 3s.

`LiveState` is the published bridge: `BLEManager` and `FrameRouter` write it; SwiftUI observes it.
`RootView` isolates the ~1 Hz HR/frame churn into a small `SidebarStatus` view so the rest of the
shell doesn't re-render on every beat.

---

## 7. Storage model (WhoopStore / SQLite)

GRDB drives a migrator (`WhoopStoreInfo.schemaVersion`, currently `11`). The schema groups into four
concerns:

**Durable decoded streams** — natural key `(deviceId, ts)`, one row per sample:
`hrSample`, `rrInterval`, `event`, `battery`, plus the type-47 biometrics `spo2Sample`,
`skinTempSample`, `respSample`, `gravitySample`.

**Metric caches** — the rolled-up shapes the screens read:
- `dailyMetric` — one row per `(deviceId, day)`: `recovery`, `strain`, sleep stage minutes,
  `restingHr`, `avgHrv`, `spo2Pct`, `skinTempDevC`, `respRateBpm`, `exerciseCount`.
- `sleepSession` — one row per `(deviceId, startTs)` with `efficiency`, `restingHr`, `avgHrv`, and
  a JSON `stagesJSON` hypnogram.
- `journal`, `workout`, `appleDaily` — imported journal answers, workouts (WHOOP + Apple Health),
  and Apple-Health daily aggregates.

**Generic metric series** — `metricSeries(deviceId, day, key, value REAL)`: a tall, long-format
table so *any* scalar metric from *any* source can be queried/compared uniformly (the substrate for
the Metric Explorer and correlations), indexed by `(deviceId, key, day)`.

**Raw outbox** — `rawBatch`: the compressed, **transient, prunable** record of original frames,
captured only when the research toggle is on. Decoded data is always committed *before* raw is queued,
so pruning raw (`PrunePolicy`: 24h window / 50MB cap) can never lose a metric. `cursors` holds durable
watermarks such as `strap_trim`.

`deviceId` is the per-source partition key. The app uses `"my-whoop"` for the strap and
`"apple-health"` for imported Apple Health, so per-source pages and cross-source "consensus" views
read the same tables filtered by source.

---

## 8. Imports (StrandImport)

Imports converge on the *same* store as the BLE paths, so history lights up instantly:

```
URL (export.zip / *.csv / export.xml / folder)
  └─▶ ImportCoordinator.detectKind  → .whoopExport | .appleHealth
        ├─ WhoopExportImporter   → cycles/sleeps/workouts/journal  → WhoopImporter      → store rows
        └─ AppleHealthImporter   → streamed export.xml (aggregated) → AppleHealthImport  → store rows
```

`StrandImport` is **parse-only**; the app's `WhoopImporter`/`AppleHealthImport` glue maps the
normalized results into `dailyMetric`, `sleepSession`, `workout`, `appleDaily`, and `metricSeries`
rows, then calls `Repository.refresh()`. Apple Health's `export.xml` is parsed with a streaming
reader so multi-hundred-MB files don't blow up memory.

---

## 9. Analytics (StrandAnalytics)

`AnalyticsEngine.analyzeDay(...)` is a pure function: given a day's raw streams (`hr`, `rr`, `resp`,
`gravity`), a `UserProfile`, and personal `ProfileBaselines`, it runs the analyzers and returns a
`DayResult`:

- **`SleepStager`** detects in-bed sessions and stages them (deep/REM/light), producing per-session
  efficiency, resting HR, average HRV, and a hypnogram.
- **`RecoveryScorer`** normalizes nightly HRV/RHR (and a sleep-performance proxy) against baselines
  into a `0–100` score.
- **`StrainScorer`** integrates the day's HR window into a `0–21` cardiovascular load (Tanaka HRmax
  from age unless overridden).
- **`WorkoutDetector`** segments exercise bouts from HR + motion.
- **`Baselines`**, **`HRZones`**, **`CorrelationEngine`**, **`ComparisonEngine`**, and
  **`BehaviorInsights`** supply rolling baselines, zone math, and cross-metric/behaviour insights.

Because the engine never touches the database, the same code runs over live-collected streams,
backfilled streams, or imported data interchangeably. **All derived values are approximate.**

---

## 10. Presentation (Strand app + StrandDesign)

`StrandApp` (`@main`) builds a single `AppModel`, injects it plus `LiveState`, `Repository`,
`ProfileStore`, and `BehaviorStore` into the environment, and presents a `WindowGroup` (dark, hidden
title bar) alongside a glanceable `MenuBarExtra`. `RootView` is a `NavigationSplitView` whose sidebar
is the `NavItem` enum (Today, Live, Breathe, Intervals, Explore, Compare, Insights, Sleep, Trends,
Workouts, Health, Stress, Apple Health, Data Sources, Notifications, Automations, Settings, Support).

Screens bind to `Repository`'s published `days`/`sleeps` caches (refreshed on data change, not on the
~1 Hz stream) and render with `StrandDesign` components — `RecoveryRing`, `StrainGauge`, `Hypnogram`,
`TrendChart`, `Sparkline`, `YearHeatStrip` — over the `StrandPalette` tokens. `AppModel` also hosts
the opt-in, on-device behaviours (HR smoothing, illness/strain early-warning, stress nudges, HR-zone
haptic coaching, double-tap actions, wrist-wear automation, smart alarm) — all default-off and all
computed locally.

---

## 11. Design principles, restated

1. **Offline by construction.** There is no network client anywhere in the data path. The strap, the
   SQLite file, and the UI are the whole system.
2. **Decoded-first durability.** Metrics are committed before raw is queued; the raw outbox is a
   prunable convenience, never the source of truth.
3. **Resumable safe-trim.** The strap forgets historical data only after NOOP has it durably and has
   confirmed the ack; a durable cursor makes every offload resumable.
4. **Pure cores, thin shell.** `WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, and `StrandImport`
   are platform-pure and testable in isolation; the app target is the only CoreBluetooth/SwiftUI
   surface.
5. **Interoperability, not impersonation.** NOOP reads your strap and your exports for your own use.
   It is independent of WHOOP and is not a medical device.

---

## Attribution

NOOP's BLE protocol work builds on community reverse-engineering of the WHOOP straps:

- **johnmiddleton12/my-whoop** — WHOOP 4.0 protocol.
- **b-nnett/goose** — WHOOP 5.0 protocol.

See [`ATTRIBUTION.md`](../ATTRIBUTION.md) for full credits and [`DISCLAIMER.md`](../DISCLAIMER.md) for
the non-affiliation and not-a-medical-device notice.
