# NOOP — Cross-Platform Swift Library Reference

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and
5.0). It pairs directly with the user's own strap over Bluetooth — **no WHOOP
cloud or account** — stores everything on-device in SQLite, can
import WHOOP CSV and Apple Health exports, and computes recovery, strain, HRV,
and sleep locally.

This document is the reference for the **reusable, cross-platform Swift
packages** that make that possible. They are designed to be vendored and reused
independently of the reference macOS app.

> **Not affiliated with WHOOP.** "WHOOP" is used nominatively only to identify
> the hardware these packages interoperate with. NOOP contains no WHOOP
> proprietary code, firmware, or assets and works only with the user's own
> device and data. **NOOP is not a medical device.** Every derived metric (HR,
> HRV, recovery, strain, sleep, SpO₂, temperature) is an approximation and is
> not clinically validated.

## Credits

These packages build on prior community reverse-engineering and
interoperability work:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE framing, command/decode,
  and collection logic that `WhoopProtocol` and `WhoopStore` are adapted from.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG protocol work (the `fd4b0001-…`
  service family, CRC16-Modbus header, `CLIENT_HELLO`, and the "puffin" packet
  types) that the WHOOP 5.0 paths are ported from.
- **`groue/GRDB.swift`** — SQLite persistence used by `WhoopStore`.

---

## Package overview

| Package | Purpose | Pure / portable? | UI deps | External deps |
|---|---|---|---|---|
| **WhoopProtocol** | BLE frame parsing, CRC, command/event/packet decode (the reverse-engineering core) | ✅ Pure Foundation | none | none |
| **WhoopStore** | GRDB/SQLite persistence: migrations, decoded streams, raw outbox, metric caches | ✅ Pure (server-free) | none | GRDB |
| **StrandAnalytics** | HRV / recovery / strain / sleep / correlation math | ✅ Pure, deterministic | none | (WhoopProtocol, WhoopStore types) |
| **StrandImport** | WHOOP CSV + Apple Health (`export.xml`, streaming) importers | ✅ Pure Foundation/XML | none | ZIPFoundation |
| **StrandDesign** | SwiftUI design system (palette, components, charts) | SwiftUI only | SwiftUI | none |

All five packages declare the same platforms — **iOS 16+ and macOS 13+** — and
build with **swift-tools-version 5.9**. The first four are platform-pure: they
never import `CoreBluetooth`, `UIKit`, or `AppKit`, so they run unchanged in CLI
tools, tests, and on any platform. `StrandDesign` is the only SwiftUI package;
it builds on both iOS and macOS, bridging through `UIColor`/`NSColor` only where
unavoidable, guarded with `#if canImport(UIKit)` / `#if canImport(AppKit)`.

### Dependency graph

```
WhoopProtocol  (no internal deps)
      │
      ├──────────────► WhoopStore        (+ GRDB)
      │                     │
      ▼                     ▼
StrandAnalytics ◄───────────┘            (depends on WhoopProtocol + WhoopStore types)

StrandImport   ──► WhoopProtocol, WhoopStore   (+ ZIPFoundation)

StrandDesign   (standalone — SwiftUI only, no internal deps)
```

The reference app target (`Strand/`, macOS SwiftUI) is the integration layer: it
owns the CoreBluetooth transport, wraps the protocol library's UUID *strings* in
`CBUUID`, and wires the pure packages together. The macOS and iOS reference apps
(the iOS target is build-from-source only) consume these packages directly, and
an Android app ships alongside them; the pure packages run unchanged across macOS
and iOS.

---

## WhoopProtocol

The reverse-engineering core: a schema-driven decoder that turns raw BLE frame
bytes from a WHOOP 4.0 or 5.0 strap into typed, annotated records. **Pure
Foundation — no CoreBluetooth, no UI.** The library deliberately exposes GATT
UUIDs as *strings* so the app layer (not this package) wraps them in `CBUUID`,
keeping the decoder runnable anywhere.

**Sources:** `Framing.swift`, `Schema.swift`, `Interpreter.swift`, `Values.swift`,
`Streams.swift`, `HistoricalStreams.swift`, `HistoricalMeta.swift`,
`DeviceFamily.swift`, `PostHooks.swift`, plus the bundled
`Resources/whoop_protocol.json` canonical decode schema.

### Depend on it

```swift
// Package.swift
dependencies: [
    .package(path: "../WhoopProtocol"),
],
targets: [
    .target(name: "MyTarget", dependencies: ["WhoopProtocol"]),
]
```

### Key public types & functions

**Device families** (`DeviceFamily.swift`)

```swift
public enum DeviceFamily: String, Sendable, CaseIterable { case whoop4, whoop5 }
```

`DeviceFamily` carries everything the transport needs without importing
CoreBluetooth:

| Member | Meaning |
|---|---|
| `headerCRCKind` | `.crc8` (WHOOP 4.0) or `.crc16Modbus` (WHOOP 5.0) |
| `serviceUUIDString` | primary GATT service UUID *string* (`6108…` / `fd4b…`) |
| `characteristicUUIDStrings` | characteristic UUID strings in stable order |
| `commandCharacteristicUUIDString` | the `…0002` write endpoint |
| `clientHello` | static `CLIENT_HELLO` frame bytes (`nil` for 4.0; a fixed type-35 frame for 5.0) |

`PuffinPacketType` and `canonicalTypeName(_:schema:)` alias WHOOP 5.0 "puffin"
types (38 → `COMMAND_RESPONSE`, 56 → `METADATA`) onto their base decode
semantics.

**CRC + framing** (`Framing.swift`)

```swift
public func crc8(_ bytes: [UInt8]) -> UInt8            // poly 0x07 (WHOOP 4.0 header)
public func crc32(_ bytes: [UInt8]) -> UInt32          // zlib CRC-32 (payload trailer)
public func crc16Modbus(_ bytes: [UInt8]) -> UInt16    // poly 0xA001 (WHOOP 5.0 header)

public func verifyFrame(_ frame: [UInt8]) -> FrameCheck
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck

public final class Reassembler {                       // accumulate BLE fragments → whole frames
    public init()
    public func feed(_ fragment: [UInt8]) -> [[UInt8]]
}
```

`FrameCheck` reports `ok`, the declared `length`, and the header/payload CRC
outcomes.

**Schema + parsing** (`Schema.swift`, `Interpreter.swift`, `Values.swift`)

```swift
public func loadSchema() -> Schema                     // loads + caches Resources/whoop_protocol.json

public func parseFrame(_ frame: [UInt8]) -> ParsedFrame
public func parseFrame(_ frame: [UInt8], family: DeviceFamily) -> ParsedFrame
```

A `ParsedFrame` carries `ok`, `typeName`, `seq`, optional `cmdName`, `crcOK`,
the full list of annotated `DecodedField`s, and a flat `parsed: [String:
ParsedValue]` dictionary. `ParsedValue` is a JSON-round-tripping scalar/array
enum (`.int`, `.double`, `.string`, `.intArray`, `.bool`, `.null`) with
`intValue` / `doubleValue` / `stringValue` / `intArrayValue` accessors.

**Decoded stream rows** (`Streams.swift`) — the durable, compact record shapes
that `WhoopStore` persists:

`HRSample`, `RRInterval`, `WhoopEvent`, `BatterySample`, `SpO2Sample`,
`SkinTempSample`, `RespSample`, `GravitySample`, all gathered into a single
`Streams` value. All carry wall-clock unix-second timestamps and are `Codable`.

```swift
// Live capture (type-40 REALTIME_DATA): HR + R-R, device clock → wall clock.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams

// Historical offload (type-47 HISTORICAL_DATA + type-43 raw headers): full biometrics.
public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                     deviceClockRef: Int, wallClockRef: Int) -> Streams
```

`classifyHistoricalMeta(_:)` (`HistoricalMeta.swift`) drives the
historical-offload state machine by classifying a parsed `METADATA` frame into
`.start`, `.end(unix:trim:)`, `.complete`, or `.other` — gated on a valid CRC32
so a garbled peer cannot forge a `HISTORY_END`.

### Minimal usage

```swift
import WhoopProtocol

// Reassemble BLE notification fragments, then decode each complete frame.
let reassembler = Reassembler()
var parsedFrames: [ParsedFrame] = []

func onNotification(_ fragment: [UInt8], family: DeviceFamily) {
    for frame in reassembler.feed(fragment) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK != false else { continue }
        parsedFrames.append(parsed)
    }
}

// Turn a batch of live frames into durable rows.
let streams = extractStreams(parsedFrames,
                             deviceClockRef: deviceEpochAtConnect,
                             wallClockRef: Int(Date().timeIntervalSince1970))
print("HR samples:", streams.hr.count, "R-R intervals:", streams.rr.count)
```

---

## WhoopStore

On-device persistence built on **GRDB/SQLite**. Decoded streams are durable;
raw frames are a transient, compressed, prunable outbox. The store is an
`actor`, so its API is `async` and all `DatabaseQueue` work runs off the main
thread on the actor's serial executor.

**Sources:** `WhoopStore.swift`, `Database.swift` (the migrator),
`StreamStore.swift`, `Reads.swift`, `RawOutbox.swift`, `Cursors.swift`,
`MetricsCache.swift`, `JournalWorkoutAppleCache.swift`, `MetricSeriesStore.swift`.

### Depend on it

```swift
// Package.swift
dependencies: [
    .package(path: "../WhoopProtocol"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "WhoopStore", package: "WhoopStore"),
    ]),
]
```

### Schema

The migrator (`WhoopStore.makeMigrator()`) runs `v1`…`v9`
(`WhoopStoreInfo.schemaVersion == 9`). On open, the store enables WAL journal
mode, `synchronous = NORMAL`, a 16 MB page cache, 256 MB mmap, and a 5-second
busy timeout so two handles to the same file don't deadlock.

| Table | Purpose | Natural key |
|---|---|---|
| `device` | known straps | `id` |
| `hrSample`, `rrInterval`, `event`, `battery` | decoded live streams | `(deviceId, ts[, …])` |
| `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample` | type-47 biometric streams | `(deviceId, ts)` |
| `rawBatch` | zlib-compressed raw-frame outbox | `batchId` |
| `cursors` | named highwater/read cursors | `name` |
| `sleepSession`, `dailyMetric` | cached derived metrics | `(deviceId, startTs)` / `(deviceId, day)` |
| `journal`, `workout`, `appleDaily` | journal + workouts + Apple-Health daily | various |
| `metricSeries` | generic long-format (EAV) metric store | `(deviceId, day, key)` |
| `scoreInputProvenance` | input provider for a NOOP-computed score | `(deviceId, day, key)` |

### Key public API

**Open / lifecycle**

```swift
public init(path: String) async throws          // open (creating) + migrate
public static func inMemory() async throws -> WhoopStore   // tests
public static let schemaVersion: Int             // on WhoopStoreInfo
```

**Write decoded streams** (idempotent upsert by natural key; returns rows
actually inserted)

```swift
public func upsertDevice(id: String, mac: String?, name: String?) async throws
@discardableResult
public func insert(_ streams: Streams, deviceId: String) async throws
    -> (hr: Int, rr: Int, events: Int, battery: Int,
        spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
```

**Range reads** (each `(deviceId, from, to, limit)`, oldest-first)

```swift
public func hrSamples(...)  -> [HRSample]
public func rrIntervals(...) -> [RRInterval]
public func events(...)      -> [WhoopEvent]
public func batterySamples(...) -> [BatterySample]
public func spo2Samples(...) / skinTempSamples(...) / respSamples(...) / gravitySamples(...)
public func latestHRSampleTs(deviceId:) async throws -> Int?
public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)
```

**Raw outbox** (`RawOutbox.swift`) — frames packed and zlib-compressed via
Apple's Compression framework:

```swift
public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
public func rawFrames(batchId: String) async throws -> [[UInt8]]
public func pendingRawBatches(limit:) async throws -> [RawBatchMeta]
@discardableResult
public func pruneRaw(now:keepWindowSeconds:maxUnsyncedBytes:) async throws -> Int
```

**Caches & cursors** — `upsertSleepSessions`, `upsertDailyMetrics`,
`sleepSessions`, `dailyMetrics` (`MetricsCache.swift`); `upsertJournal`,
`upsertWorkouts`, `upsertAppleDaily` (`JournalWorkoutAppleCache.swift`);
`upsertMetricSeries`, `metricSeries`, `metricKeys`, `metricDays`
(`MetricSeriesStore.swift`); `setCursor` / `cursor` / `setHighwater` /
`highwater` (`Cursors.swift`). The cache row models — `DailyMetric`,
`CachedSleepSession`, `JournalEntry`, `WorkoutRow`, `AppleDaily`, `MetricPoint`
— are all public `Codable` structs.

### Minimal usage

```swift
import WhoopStore
import WhoopProtocol

let store = try await WhoopStore(path: "/path/to/noop.sqlite")
try await store.upsertDevice(id: "AA:BB:CC", mac: "AA:BB:CC", name: "My WHOOP")

// Persist decoded streams (idempotent — safe to replay).
let counts = try await store.insert(streams, deviceId: "AA:BB:CC")
print("inserted HR:", counts.hr)

// Read a day back out.
let hr = try await store.hrSamples(deviceId: "AA:BB:CC",
                                   from: dayStart, to: dayEnd, limit: 100_000)
```

---

## StrandAnalytics

Pure, deterministic on-device analytics: HRV, recovery, strain, sleep staging,
workout detection, baselines, and statistical comparison/correlation. **No
database access** — every entry point is a pure function over its inputs (it
consumes the `WhoopProtocol` stream types and produces `WhoopStore` cache
shapes, but performs no I/O). All derived values are explicitly **approximate**.

**Sources:** `HRVAnalyzer.swift`, `RecoveryScorer.swift`, `StrainScorer.swift`,
`HRZones.swift`, `Baselines.swift`, `SleepStager.swift`, `WorkoutDetector.swift`,
`AnalyticsEngine.swift` (orchestrator), `CorrelationEngine.swift`,
`ComparisonEngine.swift`, `BehaviorInsights.swift`.

### Depend on it

```swift
// Package.swift
dependencies: [
    .package(path: "../WhoopProtocol"),
    .package(path: "../WhoopStore"),
    .package(path: "../StrandAnalytics"),
],
targets: [
    .target(name: "MyTarget", dependencies: ["StrandAnalytics"]),
]
```

### Key public API

| Type | Entry points |
|---|---|
| `HRVAnalyzer` | `analyze(_:windowStart:windowEnd:)` and `analyze(rawRR:)` → `HRVResult` (RMSSD, SDNN, meanNN, pNN50). Range filter [300, 2000] ms + Malik 20%-local-median ectopic rejection; needs ≥ 20 clean beats. |
| `RecoveryScorer` | `restingHR(_:start:end:)`; `recovery(...)` → 0–100 (HRV-dominant z-score + logistic composite); `band(_:)` → `"red"`/`"yellow"`/`"green"`. |
| `StrainScorer` | `strain(_:maxHR:restingHR:method:sex:denominator:)` → 0–21 (Edwards/Banister TRIMP, log-mapped); `tanakaHRmax(age:)`, `estimateHRmax(_:age:)`, `trimpToStrain(_:)`. |
| `HRZones` | `zones(age:maxHROverride:)` → `HRZoneSet`; `timeInZone(_:zoneSet:)` → `TimeInZone`. |
| `Baselines` | `update(_:value:cfg:)` → `BaselineState` (Winsorized-EWMA personal baselines + `BaselineStatus`); standard `metricCfg` for HRV / resting HR / resp / skin temp. |
| `SleepStager` | `detectSleep(hr:rr:resp:gravity:)` → `[SleepSession]` (in-bed detection + approximate 4-class staging); `hypnogramMetrics(_:)` → `HypnogramMetrics`. |
| `WorkoutDetector` | `detect(hr:gravity:restingHR:maxHR:age:profile:)` → `[ExerciseSession]`; `Calories.estimateBoutCalories(...)`. |
| `AnalyticsEngine` | `analyzeDay(day:hr:rr:resp:gravity:profile:baselines:maxHROverride:)` → `DayResult` — the orchestrator that rolls everything into a `DailyMetric` + sleep/workout sessions. |
| `CorrelationEngine` | `pearson(_:)`, `alignByDay(_:_:)`, `lagged(x:y:lagDays:)` → `Correlation`. |
| `ComparisonEngine` | `stat(_:)` → `SeriesStat`; `compare(current:previous:)` / `monthOverMonth(...)` → `PeriodComparison`. |
| `BehaviorInsights` | `effect(behaviorDays:...)` → `BehaviorEffect`; `rank(...)`, `sentence(_:)`. |

`UserProfile` (`weightKg`, `heightCm`, `age`, `sex`) is the shared profile input.

### Minimal usage

```swift
import StrandAnalytics
import WhoopProtocol

// HRV over a night's R-R intervals.
let hrv = HRVAnalyzer.analyze(rrIntervals, windowStart: bedStart, windowEnd: wakeEnd)
print("RMSSD:", hrv.rmssd ?? .nan, "ms")

// Day strain from the full HR series.
let strain = StrainScorer.strain(hrSamples, maxHR: 190, restingHR: 50)  // 0…21

// Full-day rollup (sleep + recovery + strain + workouts) in one call.
let day = AnalyticsEngine.analyzeDay(
    day: "2026-06-07",
    hr: hrSamples, rr: rrIntervals, gravity: gravitySamples,
    profile: UserProfile(weightKg: 78, heightCm: 182, age: 34, sex: "male")
)
print("recovery:", day.recovery ?? .nan, "strain:", day.strain ?? .nan)
```

---

## StrandImport

Parsers for the two export formats a user can bring offline: **WHOOP CSV**
exports and **Apple Health** exports (`export.zip` / `export.xml`, streamed so a
multi-hundred-MB file never loads fully into memory). This layer is **parsing
only** — it produces normalized Swift model arrays and an `ImportSummary` and
does not touch the database, so the whole package is unit-testable.

**Sources:** `ImportCoordinator.swift` (top-level + auto-detection),
`AppleHealthImporter.swift`, `AppleHealthAggregator.swift`,
`WhoopExportImporter.swift`, `CSVParsing.swift`, `ImportModels.swift`.

### Depend on it

```swift
// Package.swift
dependencies: [
    .package(path: "../WhoopProtocol"),
    .package(path: "../WhoopStore"),
    .package(path: "../StrandImport"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: ["StrandImport"]),
]
```

### Key public API

```swift
public struct ImportCoordinator {
    public init(appleHealth: AppleHealthImporter = .init(),
                whoop: WhoopExportImporter = .init())

    public func importAppleHealth(from url: URL) throws -> AppleHealthImportResult
    public func importWhoopExport(from url: URL) throws -> WhoopImportResult

    // Auto-detect (export.xml → Apple Health; physiological_cycles.csv etc. → WHOOP).
    public func detectKind(of url: URL) throws -> DataSourceKind
    public func detectAndImport(from url: URL) throws -> DetectedImport
}
```

- **`AppleHealthImporter`** — `import(from:)` accepts a folder, `export.zip`, or
  `export.xml`; `importXML(at:)` / `importXML(data:)` stream-parse via
  `XMLParser`. `relevantTypes` lists the captured HealthKit types (HR, resting
  HR, HRV SDNN, SpO₂, body/wrist temperature, respiratory rate, energy, VO₂max,
  steps, sleep analysis, body composition). Returns `AppleHealthImportResult`
  (`samples`, `workouts`, `sleepIntervals`, `summary`).
- **`AppleHealthAggregator`** — `daily(samples:)`, `sleepDaily(...)`,
  `aggregate(_:)` roll samples into per-civil-day `AppleDailyAggregate`s;
  `metricPoints(_:)` projects them into `(day, key, value)` triples ready for
  `WhoopStore.upsertMetricSeries`.
- **`WhoopExportImporter`** — `import(from:)` parses the CSV bundle
  (`physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`,
  `journal_entries.csv`) from a folder or `.zip`. Header-name-driven and
  tolerant (columns matched by normalized name, every column optional, BOMs
  stripped); one parser covers WHOOP 4 / 5 / MG. Returns `WhoopImportResult`
  (`cycles`, `sleeps`, `workouts`, `journal`, `summary`).

Models: `HealthSample`, `HealthWorkout`, `SleepStageInterval`, `SleepStage`,
`WhoopCycleRow`, `WhoopSleepRow`, `WhoopWorkoutRow`, `WhoopJournalRow`,
`ImportSummary`, and the `ImportError` enum.

### Minimal usage

```swift
import StrandImport

let coordinator = ImportCoordinator()

// Auto-detect WHOOP vs Apple Health and parse.
switch try coordinator.detectAndImport(from: fileURL) {
case .whoopExport(let r):
    print("WHOOP cycles:", r.cycles.count, "sleeps:", r.sleeps.count)
case .appleHealth(let r):
    let daily = AppleHealthAggregator.aggregate(r)
    let points = AppleHealthAggregator.metricPoints(daily)   // → upsertMetricSeries
    print("Apple daily rows:", daily.count)
}
```

---

## StrandDesign

The SwiftUI design system — the only UI package. Dark-only, instrument-grade:
palette, type scale, motion presets, and the signature data components
(Recovery Ring, Strain Gauge, Hypnogram, trend/sparkline charts, year heat
strip, cards, status pills). Builds on **both iOS and macOS**; it imports only
`SwiftUI` and bridges to `UIColor`/`NSColor` for color-component extraction
under `#if canImport(UIKit)` / `#if canImport(AppKit)`.

**Sources:** `Palette.swift`, `Typography.swift`, `Motion.swift`, plus the
component views `RecoveryRing.swift`, `StrainGauge.swift`, `Hypnogram.swift`,
`TrendChart.swift`, `Sparkline.swift`, `YearHeatStrip.swift`, `StrandCard.swift`,
`StatePill.swift`, `ChartHover.swift`, `Components.swift`.

### Depend on it

```swift
// Package.swift  (no internal NOOP deps — standalone)
dependencies: [
    .package(path: "../StrandDesign"),
],
targets: [
    .target(name: "MyAppUI", dependencies: ["StrandDesign"]),
]
```

### Key public API

**Tokens**

- `StrandPalette` — every semantic color token: surfaces
  (`surfaceBase`/`surfaceRaised`/`surfaceOverlay`/`surfaceInset`), `hairline`,
  text (`textPrimary`/`textSecondary`/`textTertiary`), `accent`, the recovery
  gradient stops (`recoveryStops`), floating-glass rim/tint/elevation tokens,
  and recovery/strain color sampling. A `Color(hex:)` initializer supports
  `RRGGBB` / `RRGGBBAA`.
- `StrandFont` — the full type scale with tabular digits: `display(_:)`,
  `title1`/`title2`, `headline`, `body`, `subhead`, `caption`, `caption2`, `footnote`,
  `overline`, `mono(_:weight:)`, `number(_:weight:)`, and
  `symbol(_:weight:)` for token-sized SF Symbols.
- `StrandMotion` — spring/animation presets: `interactive`, `gentle`, `hero`,
  `drawIn`, `breathe`, `pulse`, `fade`, `calm`, `calmQuick`, `panel`, `tap`,
  `quick`, `lift`, and `jiggle(halfCycle:delay:)`, plus the
  `durationFast`/`durationStandard`/`durationSlow` constants. Reduced-motion
  overloads return `nil` for transitions that should become instantaneous.
- `NoopMetrics` — the canonical spacing and sizing scale. The nested
  `NoopMetrics.LaunchChrome` namespace owns all geometry for the iOS floating
  tab bar and quick-launch panel, including compact visual sizes and the
  remove badge's separate interaction target.

**Surface modifiers**

- `noopLiquidGlassSurface(in:)` — the canonical iOS floating-navigation material,
  including the iOS 26 Liquid Glass effect, pre-iOS-26 material fallback, tint,
  rim, and elevation. The split tab bar and quick-launch panel use this same
  modifier so their appearance stays identical.

**Components** (all public `View`s)

| View | Role |
|---|---|
| `RecoveryRing` | 240° open gauge arc; the signature recovery read-out |
| `StrainGauge` | 0–21 strain gauge |
| `Hypnogram` | sleep-stage timeline |
| `TrendChart`, `Sparkline`, `ChartHover` | line/area charts + hover read-out |
| `YearHeatStrip` | year-at-a-glance heat strip |
| `StrandCard`, `NoopCard`, `ChartCard`, `InsightCard` | card containers |
| `StatePill`, `ConnectionDot`, `SourceBadge` | status chips / source labels |
| `SectionHeader`, `StatTile`, `ChartFooter`, `SegmentedPillControl` | layout primitives |

### Minimal usage

```swift
import SwiftUI
import StrandDesign

struct RecoveryHeader: View {
    let score: Double
    var body: some View {
        VStack(spacing: 16) {
            RecoveryRing(score: score,
                         supporting: "HRV 62ms · RHR 51",
                         diameter: 240, lineWidth: 16)
            Text("Today")
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding()
        .background(StrandPalette.surfaceBase)
    }
}
```

---

## Reuse notes

- **Pick only what you need.** `WhoopProtocol` is self-contained (no
  dependencies); `WhoopStore` adds GRDB; `StrandImport` adds ZIPFoundation;
  `StrandAnalytics` consumes the first two's types but does no I/O. A headless
  tool can decode and analyze WHOOP data with no SwiftUI involved at all.
- **Bring your own transport.** The protocol library never opens a Bluetooth
  connection. Wire `DeviceFamily.serviceUUIDString` / `characteristicUUIDStrings`
  into your platform's BLE stack, feed notification bytes through `Reassembler`,
  and decode with `parseFrame(_:family:)`.
- **Determinism.** The analytics and protocol packages are pure and
  deterministic — the same inputs always yield byte-identical outputs, which is
  what makes their golden-fixture tests possible and what makes them safe to run
  fully offline on the user's own data.
