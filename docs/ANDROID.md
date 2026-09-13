# NOOP — Android Port Guide

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and 5.0). It pairs
directly with the strap over Bluetooth Low Energy, stores everything on-device in SQLite, imports
WHOOP CSV exports and Apple Health exports, and computes recovery / strain / HRV / sleep locally.
There is no cloud, no account — the app talks only to **your own device** and
works only with **your own data**.

This document covers the **Android client** under [`android/`](../android). The macOS app is the
reference implementation; the Android app is a native re-implementation of the same wire protocol
and on-device data model, not a wrapper around the Swift code. (A third target, **iOS**, is folded
into the main project as a **build-from-source-only** client — see the macOS/iOS docs — and shares
the same analytics so results match macOS.)

> **Not affiliated with WHOOP, and not a medical device.** "WHOOP" is used nominatively only to
> identify the hardware this software interoperates with. NOOP contains no WHOOP code, firmware, or
> assets, and performs no DRM circumvention — it talks only to the user's own device and the data it
> has already recorded. All outputs (HR, HRV, recovery, strain, sleep, SpO₂, temperature) are
> approximations and are **not** clinically validated. See [`../DISCLAIMER.md`](../DISCLAIMER.md)
> and [`../ATTRIBUTION.md`](../ATTRIBUTION.md).

> ### Status: shipping platform — builds, releases, and validated on WHOOP 4.0
>
> The Android client is a **fully shipping** part of NOOP. It builds and releases as two APK
> flavours — **full** (`./gradlew assembleFullRelease`) and **demo** (`./gradlew
> assembleDemoRelease`) — and is sideloaded by users (with features such as a **Sync-now** button).
> The BLE pipeline, Compose UI, Room database, and importers are all present and working. It is
> validated against a real **WHOOP 4.0** strap, and **live HR** is validated on **WHOOP 5.0 / MG**;
> deeper 5.0/MG scores are still being reverse-engineered from offload data. The
> [verification checklist](#verification-checklist) below tracks what's confirmed versus the
> genuinely-open items (chiefly full 5.0/MG deep-score validation).

---

## Table of contents

- [Design intent](#design-intent)
- [Project structure](#project-structure)
- [What exists vs. what is missing](#what-exists-vs-what-is-missing)
- [Build prerequisites](#build-prerequisites)
- [Building](#building)
- [Installing the APK (sideload & Play Protect)](#installing-the-apk-sideload--play-protect)
- [The protocol module (Kotlin port of `WhoopProtocol`)](#the-protocol-module-kotlin-port-of-whoopprotocol)
- [Android BLE layer](#android-ble-layer)
- [Storage with Room](#storage-with-room)
- [Raw capture import (`capture.json`)](#raw-capture-import-capturejson)
- [Analytics](#analytics)
- [Compose UI](#compose-ui)
- [Permissions and the no-internet posture](#permissions-and-the-no-internet-posture)
- [Verification checklist](#verification-checklist)
- [Credits](#credits)

---

## Design intent

The Android app deliberately **does not** share a binary with the Swift packages. Instead it
re-implements the same observable behavior in idiomatic Kotlin:

| Swift package (reference) | Android counterpart | Status |
| --- | --- | --- |
| `WhoopProtocol` — BLE framing, CRC, command/event/packet decode | `com.noop.protocol` (Kotlin) | shipped — framing/CRC, `parseFrame`, enums |
| `WhoopStore` — GRDB/SQLite persistence | `com.noop.data` (Room) | shipped — entities, DAOs, database |
| `StrandAnalytics` — HRV / recovery / strain / sleep math | `com.noop.analytics` | shipped — RMSSD / zones / illness-watch + scorers |
| `StrandImport` — WHOOP CSV + Apple Health importers | `com.noop.data` / `com.noop.ingest` importers | shipped — WHOOP CSV, Apple Health, Health Connect, raw `capture.json` (see [Raw capture import](#raw-capture-import-capturejson)) |
| `StrandDesign` — SwiftUI design system | Jetpack Compose theme | shipped — `Theme.NOOP` tokens + components |
| `Strand/` macOS app (CoreBluetooth + UI) | `com.noop.ui` + `com.noop.ble` (Compose + `BluetoothGatt`) | shipped — Compose screens + BLE pipeline |

The single source of truth that **both** platforms must agree on is the protocol schema resource
`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` (top-level keys
`version`, `enums`, `envelope`, `packets`) and the SQLite schema defined by the GRDB migrations in
`Packages/WhoopStore/Sources/WhoopStore/Database.swift`. Port against those files, not against
memory.

---

## Project structure

`android/` is a **single Gradle project** (Kotlin + Jetpack Compose), one application module named
`:app`:

```
android/
├── settings.gradle.kts          # rootProject.name = "NOOP"; include(":app")
├── build.gradle.kts             # root: declares AGP / Kotlin / KSP plugin versions (apply false)
├── gradle.properties            # JVM args, AndroidX on, R8 full mode, parallel/caching
├── gradlew / gradlew.bat        # committed wrapper scripts
├── gradle/wrapper/              # gradle-wrapper.{jar,properties} (committed)
└── app/
    ├── build.gradle.kts         # namespace com.noop, applicationId com.noop.whoop, Compose + Room
    ├── proguard-rules.pro       # R8 release rules
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   ├── java/com/noop/
        │   │   ├── NoopApplication.kt
        │   │   ├── protocol/    # Crc.kt, Framing.kt, ParseFrame.kt, Schema.kt, DeviceFamily.kt, Commands.kt
        │   │   ├── data/        # Entities.kt, *Dao.kt, NoopDatabase.kt, importers (CSV + Apple Health)
        │   │   ├── analytics/   # Analytics.kt + StrandAnalytics scorers
        │   │   ├── ble/         # BluetoothGatt manager, frame router, collector, backfiller
        │   │   └── ui/          # MainActivity + Compose screens
        │   └── res/values/      # colors.xml, themes.xml, strings.xml
        └── test/java/com/noop/
            └── analytics/AnalyticsTest.kt
```

### Version contract

From `android/build.gradle.kts` and `android/app/build.gradle.kts` — keep these aligned; a Kotlin
bump forces matching KSP and Compose-compiler bumps:

| Component | Version | Notes |
| --- | --- | --- |
| Android Gradle Plugin | `8.5.2` | `com.android.application` |
| Kotlin | `1.9.24` | `org.jetbrains.kotlin.android` |
| KSP | `1.9.24-1.0.20` | `<kotlinVersion>-<kspVersion>`, must track Kotlin exactly |
| Compose BOM | `2024.06.00` | pins all Compose artifacts in lockstep |
| Compose compiler extension | `1.5.14` | matched to Kotlin 1.9.24 |
| Room | `2.6.1` | `room-runtime`, `room-ktx`, `room-compiler` (via KSP) |
| `compileSdk` / `targetSdk` | `34` | |
| `minSdk` | `26` | Android 8.0 — the floor for the current BLE permission split |
| `sourceCompatibility` / `jvmTarget` | `17` | JDK 17 |
| `applicationId` | `com.noop.whoop` | `.debug` suffix on debug builds |

The app declares **no `INTERNET` permission** by design (see
[Permissions](#permissions-and-the-no-internet-posture)) and sets `android:allowBackup="false"`.

---

## What exists vs. what is missing

The Android client is built, released, and validated, so the layers below all **exist and work**.
This section maps the surface so contributors know where each piece lives.

**Present and working** (under `android/app/src/main/java/com/noop/`):

- `protocol/Crc.kt` — `Crc.crc8`, `Crc.crc32`, `Crc.crc16Modbus`. **Ported verbatim** from
  `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` (same CRC8 table, same zlib CRC-32
  table generation, same CRC16-Modbus loop). Returns are widened (`Int`/`Long`) because Kotlin has
  no commonly-used unsigned return types, but carry only the low 8/16/32 bits.
- `protocol/Framing.kt` — `verifyFrame` (both families) and `Reassembler` for BLE-fragment
  reassembly; `protocol/ParseFrame.kt` — schema-driven `parseFrame` (4.0) / `parseFrame(family:)`
  (5.0); `protocol/Schema.kt` + the bundled `whoop_protocol.json` asset; `protocol/DeviceFamily.kt`
  (service/char UUIDs, CLIENT_HELLO); `protocol/Commands.kt` (the curated, safe `WhoopCommand`).
- `data/Entities.kt` — Room `@Entity` classes mirroring the GRDB schema: `DeviceRow`, `HrSample`,
  `RrInterval`, `EventRow`, `BatterySample`, `Spo2Sample`, `SkinTempSample`, `RespSample`,
  `GravitySample`, `DailyMetric`, `SleepSession`, `MetricSeriesRow` — with DAOs and the
  `@Database`. Natural/composite keys match the Swift `ON CONFLICT … DO NOTHING` upserts (use
  `OnConflictStrategy.IGNORE`). Importers cover **WHOOP CSV** and **Apple Health** exports.
- `ble/*` — the `BluetoothGatt` manager, frame router, collector, and backfiller that drive the
  connect → bond → stream → offload pipeline (validated on a real WHOOP 4.0; live HR on 5.0/MG).
- `analytics/Analytics.kt` — `Hrv.rmssd`, `Zones.zone` / `Zones.hrMaxTanaka`, `IllnessWatch.evaluate`
  (ported from `Strand/App/AppModel.swift`), alongside the heavier scorers ported from
  `StrandAnalytics`.
- `ui/*` — `MainActivity` plus the Compose (Material 3) screens; `NoopApplication` as the
  `Application` subclass.
- `test/java/com/noop/analytics/AnalyticsTest.kt` — JUnit unit tests for the analytics
  (RMSSD known-vector, zone ladder/boundaries, Tanaka rounding, illness-watch flag logic).
- Manifest, `res/values/{colors,themes,strings}.xml`, launcher mipmaps,
  `res/xml/data_extraction_rules.xml`, `app/proguard-rules.pro` (R8 release), and the committed
  Gradle wrapper (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.{jar,properties}`).

**Still being reverse-engineered** (not a build gap — a data gap):

| Area | State |
| --- | --- |
| WHOOP 5.0 / MG deep scores (recovery / strain / sleep depth) | live HR works on 5.0/MG; the derived scores are still being RE'd from offload data, so they build slowly without sustained wear |
| Remaining Swift tables not yet mirrored as Room entities (`rawBatch`, `cursors`, `journal`, `workout`, `appleDaily`) | add as the corresponding collector / journal / workout features are ported |

---

## Build prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| JDK | **17** | AGP 8.5 / Kotlin 1.9 target JVM 17 |
| Android SDK | API **34** platform + build-tools; `minSdk` 26 | install via Android Studio SDK Manager or `sdkmanager` |
| Android Studio | current stable (Koala / Ladybug or newer) | optional but recommended; provides the SDK and emulator |
| Gradle | provided by the committed wrapper (target ~8.7) | use `./gradlew`; do not rely on a global Gradle |
| A physical WHOOP 4.0 or 5.0 strap | — | **required** for any real BLE validation; emulators have no BLE radio |
| A physical Android device with BLE | Android 8.0+ (API 26+) | the emulator **cannot** reach a real strap |

Point Gradle at the SDK with `android/local.properties` (untracked):

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

or export `ANDROID_HOME` / `ANDROID_SDK_ROOT`.

---

## Building

> The Android client builds and ships today. It releases as two flavours — **full** and **demo** —
> via `assembleFullRelease` / `assembleDemoRelease`. The pure-Kotlin unit tests run without a device.

```bash
cd android

# Run the pure-Kotlin unit tests (analytics). No device needed.
./gradlew :app:testDebugUnitTest

# Assemble a debug APK.
./gradlew assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk  (applicationId com.noop.whoop.debug)

# Install onto a connected device and launch.
./gradlew installDebug
adb shell am start -n com.noop.whoop.debug/com.noop.ui.MainActivity

# Release builds — the two shipped flavours (R8 full mode + resource shrink are enabled).
./gradlew assembleFullRelease    # → NOOP-full.apk
./gradlew assembleDemoRelease    # → NOOP-demo.apk
```

Open `android/` directly in Android Studio (**File ▸ Open ▸ android/**) and let Gradle sync; run
the `app` configuration on a physical device.

---

## Installing the APK (sideload & Play Protect)

The released `NOOP-full.apk` is an **unsigned, source-available APK** — there
is no Play Store listing, because the project is anonymous and has no paid Play identity to publish
or sign under. That's deliberate, but it means Android treats NOOP as an "unknown app" and **Google
Play Protect** may warn or block on install — most stubbornly on stock Pixel / recent Android.
Nothing is wrong with the file; it's just missing a Play signature. To get it on:

1. **Tap "Install anyway."** When the warning appears, choose **More details → Install anyway**.
2. **If that button is missing** — it can vanish after a first install + uninstall — grant the source
   directly: **Settings → Apps → Special app access → Install unknown apps → [the browser or file
   manager you're installing from] → Allow from this source**, then reopen the APK.
3. **If Play Protect still refuses**, it's your call for an unsigned app you trust: **Play Store →
   profile icon → Play Protect → ⚙ Settings → "Scan apps with Play Protect" off**, install NOOP,
   then switch it **back on**.
4. **Reinstalling is safe.** The app sets `android:allowBackup="false"` and keeps everything in
   private on-device storage, so uninstalling and reinstalling simply starts fresh — there's no cloud
   copy to lose, and nothing leaves the device either way.

A sample-data **demo** flavour still exists for exploring every screen with no strap, but it's
**build-from-source only** (`./gradlew assembleDemoDebug`) and is no longer published as a release
asset. It installs alongside the full app (distinct `applicationId`), so you can keep both.

---

## The protocol module (Kotlin port of `WhoopProtocol`)

The protocol module is the reverse-engineering core. It is **platform-pure**: it must not import
any Android Bluetooth types, so it can be unit-tested on the JVM exactly like `WhoopProtocol` runs
in Swift CLI tools and tests. The BLE layer is responsible for turning the UUID *strings* the
protocol exposes into `android.os.ParcelUuid` / `UUID` values.

### Framing and CRCs (`Crc.kt`, present)

Already ported verbatim from `Framing.swift`:

| Function | Algorithm | Guards |
| --- | --- | --- |
| `Crc.crc8(data)` | CRC-8, poly `0x07`, table-driven | WHOOP 4.0 frame length header |
| `Crc.crc32(data)` | zlib CRC-32, reflected, poly `0xEDB88320` | the frame payload (both families) |
| `Crc.crc16Modbus(data)` | CRC16-Modbus, poly `0xA001`, init `0xFFFF`, reflected | WHOOP 5.0 frame header |

### Frame envelopes (`Framing.swift` → `Framing.kt`, ported)

Two families, one payload CRC. `Framing.kt` ports `verifyFrame(_:)`, `verifyFrame(_:family:)`,
`frameFromPayload(...)`, and `Reassembler` from `Framing.swift` — keep them in step when the
envelopes change.

**WHOOP 4.0 envelope** (`DeviceFamily.whoop4`, CRC8 header):

```
[0]      SOF 0xAA
[1..2]   length  u16 LE
[3]      crc8(length bytes)
[4]      packet type
[5]      seq
[6]      cmd
[7..]    payload
[len..]  crc32 (zlib, LE) over inner bytes [4 .. len)
total = length + 4
```

**WHOOP 5.0 / MG envelope** (`DeviceFamily.whoop5`, CRC16-Modbus header — from the goose work):

```
[0]      SOF 0xAA
[1]      format byte (0x01)
[2..3]   declaredLength u16 LE   (= payload length + 4)
[4..5]   header bytes
[6..7]   CRC16-Modbus over frame[0..6], u16 LE
[8..]    inner record: [type][seq][cmd][data…]
tail     crc32 (zlib, LE) over the payload, 4 bytes
total = declaredLength + 8
```

`Reassembler.feed(fragment)` accumulates BLE notification fragments and emits complete frames; a
complete WHOOP 4.0 frame is `length + 4` bytes where `length = u16 LE at buf[1..3]`. Port the
`firstIndex(of: 0xAA)` resync logic exactly — partial fragments are the norm over GATT notifications.

### Decode (`Interpreter.swift` → `ParseFrame.kt`, ported)

`parseFrame(frame)` (WHOOP 4.0) and `parseFrame(frame, family)` (WHOOP 5.0) build a `ParsedFrame`
with `ok`, `typeName`, `seq`, `cmdName`, `crcOK`, `fields`, and a flat `parsed` map. The decoder is
**schema-driven** — it reads static field offsets/dtypes/enums from the bundled
`whoop_protocol.json`, then applies a per-type post-hook for irregular fields. The Kotlin port:

1. Bundles `whoop_protocol.json` as an `assets/` resource (or `res/raw/`) and parses it into a
   `Schema` data class mirroring `Schema.swift` (`enums`, `envelope`, `packets`, with a
   `byType` index built from each packet's `type` + `aliases`).
2. Implements the LE readers (`u8`/`u16`/`u32`/`i16`, nullable on out-of-range) and the
   `FieldBuilder`/post-hook pattern from `Interpreter.swift`.
3. Aliases the WHOOP 5.0 "puffin" packet types onto their base names via `canonicalTypeName`:
   `38 (PUFFIN_COMMAND_RESPONSE) → COMMAND_RESPONSE`, `56 (PUFFIN_METADATA) → METADATA`
   (`DeviceFamily.swift`).

The enum groups in `whoop_protocol.json` are `PacketType` (16 entries), `MetadataType`,
`EventNumber`, and `CommandNumber` (77 entries). Decode the command name for COMMAND (35) /
COMMAND_RESPONSE (36) frames via the `CommandNumber` enum.

### Device family + GATT identity (`DeviceFamily.swift` → `DeviceFamily.kt`, ported)

`DeviceFamily` exposes everything the BLE layer needs as plain strings. These constants are ported
verbatim — keep them exact:

| | WHOOP 4.0 (`whoop4`) | WHOOP 5.0 (`whoop5`) |
| --- | --- | --- |
| Header CRC | CRC8 (poly 0x07) | CRC16-Modbus |
| Service UUID | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command/write char | `61080002-…` | `fd4b0002-…` |
| Other chars | `…0003, …0004, …0005` | `…0003, …0004, …0005, …0007` |
| CLIENT_HELLO | none | `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D` |

The WHOOP 5.0 CLIENT_HELLO is a fully-formed type-35 (COMMAND) frame written immediately after GATT
discovery; transcribe it verbatim (`DeviceFamily.whoop5ClientHello`).

### Commands (`Commands.swift` → `Commands.kt`, ported)

The `CommandNumber` sender set ports the **curated, safe** `WhoopCommand` enum from
`Strand/BLE/Commands.swift`. It intentionally **excludes** destructive commands (firmware load,
force-trim, ship-mode, power-cycle, fuel-gauge reset, BLE DFU) so the command sender can never brick
or wipe the strap — preserve that exclusion. The one guarded exception is `REBOOT_STRAP` (a plain,
non-destructive restart), sent only from the user-initiated, confirmation-gated Restart action
(`WhoopBleClient.rebootStrap()`) — never automatically (#166). Raw values are the on-wire command
codes; the ones the connect/offload lifecycle relies on:

| Command | Code | Role |
| --- | --- | --- |
| `toggleRealtimeHR` | 3 | start/stop realtime HR stream |
| `setClock` | 10 | set strap RTC (8-byte payload: `[seconds u32 LE][subseconds u32 LE]`) |
| `getClock` | 11 | request device↔wall clock correlation (**empty** payload) |
| `sendHistoricalData` | 22 | trigger the type-47 historical offload (payload `[0x00]`) |
| `historicalDataResult` | 23 | ack a HISTORY_END chunk (`[0x01] + endData`, confirmed write) |
| `getBatteryLevel` | 26 | also used as the **bond** write |
| `getDataRange` | 34 | refresh the strap's stored range for the liveness watchdog |
| `getHelloHarvard` | 35 | session hello |
| `sendR10R11Realtime` | 63 | the real on/off for the type-43 raw flood (`[0x00]` to stop) |
| `setAlarmTime` / `getAlarmTime` / `runAlarm` / `disableAlarm` | 66/67/68/69 | firmware alarm |
| `runHapticsPattern` | 79 | buzz the motor (`[patternId, numLoops, 0,0,0]`) |

`WhoopCommand.frame(seq, payload)` builds the framed COMMAND packet for WHOOP 4.0:
`[0xAA][len u16 LE][crc8(len)][type=35][seq][cmd][payload…][crc32 LE]`, where `len = (3 + payload) + 4`,
crc8 is over the two length bytes, and crc32 (zlib) is over `[type][seq][cmd][payload]`. Port this
builder exactly — it is the most-exercised write path.

---

## Android BLE layer

This is the **trickiest** part of the port — Android's GATT stack is stricter than CoreBluetooth —
but it is implemented and **validated on a real WHOOP 4.0** (live HR confirmed on 5.0/MG). The
macOS reference is `Strand/BLE/BLEManager.swift` (CoreBluetooth); the Android equivalent uses
`BluetoothGatt`. The **sequence is identical**; only the API differs. The notes below document how
the Android layer mirrors the reference so future changes stay in parity.

### CoreBluetooth → Android mapping

| CoreBluetooth (macOS, verified) | Android `BluetoothGatt` (to build) |
| --- | --- |
| `CBCentralManager.scanForPeripherals(withServices: [service])` | `BluetoothLeScanner.startScan(filters, settings, callback)` with a `ScanFilter` on the service UUID |
| `central.connect(peripheral)` | `device.connectGatt(context, autoConnect=false, gattCallback, TRANSPORT_LE)` |
| `peripheral.discoverServices(...)` | `gatt.discoverServices()` → `onServicesDiscovered` |
| `peripheral.writeValue(_, for:, type: .withResponse)` | `gatt.writeCharacteristic(...)` with `WRITE_TYPE_DEFAULT` (API 33+: `writeCharacteristic(char, value, writeType)`) |
| `.withoutResponse` | `WRITE_TYPE_NO_RESPONSE` |
| `peripheral.setNotifyValue(true, for:)` | `gatt.setCharacteristicNotification(char, true)` **plus** write `ENABLE_NOTIFICATION_VALUE` to the `0x2902` CCCD descriptor |
| `didUpdateValueFor` delegate | `onCharacteristicChanged` callback |
| `didWriteValueFor` (confirmed-write = bond) | `onCharacteristicWrite` with `GATT_SUCCESS` |

### The connect → bond → stream sequence (must match `BLEManager`)

1. **Scan** filtered by the family service UUID (`61080001-…` for 4.0, `fd4b0001-…` for 5.0).
2. **Connect** and **discover services**, then discover the family characteristics.
3. **BOND via one confirmed write.** This is the load-bearing trick: writing
   `GET_BATTERY_LEVEL` (cmd 26) to the command/write characteristic (`…0002`) with
   `WRITE_TYPE_DEFAULT` triggers just-works bonding. On Android, prefer letting the GATT write drive
   pairing; you may also need to handle `BluetoothDevice.createBond()` / the
   `ACTION_BOND_STATE_CHANGED` broadcast depending on the OEM stack. Bond confirmation =
   `onCharacteristicWrite(GATT_SUCCESS)`.
4. **Subscribe** (notify) to the command-notify, event-notify, and data-notify characteristics
   (`…0003/0004/0005`), plus the standard Heart Rate (`0x2A37`, service `0x180D`) and Battery
   (`0x2A19`, service `0x180F`) characteristics. The standard HR profile is the **reliable** R-R
   and HR source and works **unbonded**.
5. **Run the connect handshake EXACTLY ONCE per connection.** On macOS this is guarded by
   `connectHandshakeDone` because `didWriteValueFor` re-fires on every confirmed write; the same
   guard is mandatory on Android (`onCharacteristicWrite` likewise fires per write). Re-blasting
   `hello`/`SET_CLOCK` mid-offload was the documented root cause of the strap refusing to serve
   type-47. The handshake: `getHelloHarvard` → `getAdvertisingNameHarvard` → `setClock` →
   `getClock` (empty payload) → `sendR10R11Realtime [0x00]` (stop the raw flood) → `getDataRange`,
   then after ~1.5 s start the historical offload.
6. **Reassemble** notification fragments on the three custom characteristics through `Reassembler`,
   route each complete frame, run clock correlation, and during a backfill route only genuine
   offload frames (types `47/48/49/50` — HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS), dropping
   the live `40/43` flood so the idle watchdog tracks real progress.

### Android-specific BLE gotchas

- **Serialize GATT operations.** Unlike CoreBluetooth, Android's GATT stack allows **one
  outstanding operation at a time**. Queue writes / reads / descriptor writes and only issue the
  next on the matching callback, or operations will silently drop. The Swift `send(...)` path is
  fire-and-forget because CoreBluetooth queues internally; the Kotlin port must add its own queue.
- **CCCD descriptor.** `setCharacteristicNotification(true)` alone is not enough on Android — you
  must also write `BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE` to the Client Characteristic
  Configuration descriptor (`00002902-0000-1000-8000-00805f9b34fb`).
- **MTU.** Consider `requestMtu(...)` after connect; the reassembler tolerates any fragment size, so
  this is an optimization, not a correctness requirement.
- **Foreground service.** To keep collecting/offloading while backgrounded, run the GATT work inside
  a foreground service of type `connectedDevice` (the manifest already declares
  `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`). Android has no direct analogue to
  CoreBluetooth state restoration — a foreground service is the equivalent mechanism.
- **Strap must be out of range of the official app** during initial bonding, worn, and charged
  enough to report a non-zero heart rate.

### Debugging the strap connection

The BLE client keeps a running **strap log** of the connection's control flow — scan results,
the bond/handshake state machine, every command sent (name + payload hex), and offload progress
(trim cursors, chunk acks). It is the primary tool for **debugging and protocol development** on
Android, and the same log is what users attach to bug reports.

By default the log is kept **only** in an in-memory ring buffer (so a normal user never writes the
connection log to the device-wide system log). To watch a session live while developing, turn the
log on:

1. In the app: **Settings → Strap → "Debug logging"** (off by default).
2. Then tail it over adb, filtered to the BLE client tag:

   ```bash
   adb logcat -s WhoopBleClient
   # e.g.
   #   D WhoopBleClient: Discovered WHOOP 5AG… (rssi -52) — connecting
   #   D WhoopBleClient: → TOGGLE_REALTIME_HR payload=01 (puffin)
   #   D WhoopBleClient: Backfill: acked chunk trim=113681
   #   D WhoopBleClient: Backfill: session ended — reason=HISTORY_COMPLETE
   ```

The toggle drives `WhoopBleClient.debugLogcat` (persisted as `NoopPrefs.KEY_DEBUG_LOGGING`); it
gates only the `Log.d` call. Whether or not it is on, **Settings → Strap → "Share strap log"**
exports the same in-app buffer to a file (the path for users with no adb). What the log does and
does not contain — and why logcat is opt-in — is covered in `PRIVACY_SECURITY.md` §2.4.

---

## Storage with Room

`com.noop.data.Entities.kt` mirrors the GRDB schema from
`Packages/WhoopStore/Sources/WhoopStore/Database.swift`, with DAOs and the `@Database` in place. The
storage layer holds these invariants — preserve them when extending it:

- **Composite natural keys preserved exactly** so `OnConflictStrategy.IGNORE` reproduces the Swift
  `ON CONFLICT(...) DO NOTHING` dedupe:

  | Entity | Table | Primary key |
  | --- | --- | --- |
  | `HrSample` | `hrSample` | `(deviceId, ts)` |
  | `RrInterval` | `rrInterval` | `(deviceId, ts, rrMs)` |
  | `EventRow` | `event` | `(deviceId, ts, kind)` |
  | `BatterySample` | `battery` | `(deviceId, ts)` |
  | `Spo2Sample` | `spo2Sample` | `(deviceId, ts)` |
  | `SkinTempSample` | `skinTempSample` | `(deviceId, ts)` |
  | `RespSample` | `respSample` | `(deviceId, ts)` |
  | `GravitySample` | `gravitySample` | `(deviceId, ts)` |
  | `DailyMetric` | `dailyMetric` | `(deviceId, day)` |
  | `SleepSession` | `sleepSession` | `(deviceId, startTs)` |
  | `MetricSeriesRow` | `metricSeries` | `(deviceId, day, key)` + index `idx_metricSeries_device_key_day (deviceId, key, day)` |
  | `ScoreInputProvenanceRow` | `scoreInputProvenance` | `(deviceId, day, key)` + index `idx_scoreInputProvenance_source (sourceId)` |
  | `DeviceRow` | `device` | `id` |

- **Timestamps are wall-clock unix seconds.** Swift stores them as `Int`; the entities widen to
  `Long` for safety. `day` columns are `"YYYY-MM-DD"` strings.
- **`payloadJSON` is deterministic sorted-keys JSON** (the parsed event fields minus
  `event`/`event_timestamp`). Match `StreamStore.encodePayload` so event rows are byte-identical
  across platforms.
- **Schema version parity.** The GRDB migrations run `v1`…`v9`. The entities already carry forward
  later additions (e.g. `synced` flags, `battery.charging` from v6, the v7 in-sleep aggregates
  `spo2Pct`/`skinTempDevC`/`respRateBpm`, and the v9 `metricSeries`). The Room `@Database` carries a
  matching `version` and migrations to reach the same logical schema; Room generates the SQL, so
  verify the emitted `CREATE TABLE`/index against `Database.swift` when you change it rather than
  assuming.

A few Swift tables are not yet mirrored as Room entities (`rawBatch`, `cursors`, `journal`,
`workout`, `appleDaily`) — add them as the corresponding collector / journal / workout features are
ported.

The database is created **without** an `INTERNET` permission and lives entirely in the app's private
storage; nothing is uploaded.

---

## Raw capture import (`capture.json`)

**Settings → Data Sources → "Raw capture (.json)"** imports a strap offload that was captured on
*another* device — most usefully the Linux `Tools/linux-capture/whoop_sync.py` tool, whose `export`
subcommand writes exactly this format. It lets you pull a strap's history on a laptop (no phone, no
WHOOP app) and then fold it into NOOP on the phone. Fully offline; nothing leaves the device.

**File format.** A JSON array of frame objects, one per stored BLE notify frame:

```json
[ {"hex": "aa50…", "char": "61080003-…", "ts_ms": 1718000000000, "hr": 75}, … ]
```

- `hex` — the raw strap frame, hex-encoded.
- `char` — the notify-characteristic UUID; its family marker selects the decoder (`6108…` → WHOOP 4,
  `fd4b…` → WHOOP 5/MG). Frames with an unrecognised `char` are skipped.
- `ts_ms` / `hr` — informational only; decoding uses each record's own embedded unix timestamp.

The format is identical to the macOS app's frame-export hook, so captures are interchangeable across
platforms and feed the one decoder of record.

**Pipeline** (`com.noop.ingest.CaptureImporter`, a self-contained object with `CaptureImporterTest`
covering the pure parts). The Data Sources screen wires it with a single call —
`CaptureImporter.importCapture(context, uri, repo, RawHistoryArchive(context))`, then sizes the
post-import rescore via `CaptureImporter.analyzeWindowDays(firstDay, today)`:

1. **Parse — streamed and bounded.** A `capture.json` for a multi-day offload is tens of MB and
   hundreds of thousands of frames; loading it whole into a `String` + `JSONArray` OOMs a phone.
   Instead a small `JsonArrayScanner` pulls one top-level array element at a time off the SAF input
   stream (respecting strings, escapes and nested braces), handing each object to `org.json` for field
   parsing. Because the file is **untrusted user input**, the scan is bounded — a cap on bytes read, a
   cap on frames kept (excess flagged, not crashed), a per-frame hex-length ceiling, and strict hex
   validation — so a malformed or oversized file is rejected cleanly. Peak memory is the per-family
   frame lists plus one element substring — not the whole file.
2. **Decode — reuses the live path.** Frames are filtered to offload frames and run through the SAME
   `extractHistoricalStreams` decoder the live BLE offload uses (`clockRef 0/0`, since historical
   records carry their own unix). There is no second decoder to drift, and the live BLE analyze path is
   untouched.
3. **Insert.** Decoded streams go through `WhoopRepository.insert(batch, "my-whoop")` — the same
   natural-key-deduped write as the live offload, so re-importing the same file is idempotent.
4. **Archive the rest.** Frames the current decoder can't yet map are reject-archived (via
   `RawHistoryArchive`) so a future release can recover them — exactly as the live offload archives
   undecodable history before acking.
5. **Recompute.** Raw samples are stored, but the dashboard reads *computed* recovery / strain / sleep,
   produced by `IntelligenceEngine`. The screen fires one scoring pass right after the import, widening
   the look-back via `analyzeWindowDays` to cover the import's oldest day so an old historical capture
   is scored, not just the recent window.

**Caveats.**

- **Recovery needs ≥7 baseline nights** (`ReadinessEngine`), so a short capture imports sleep / strain
  / HRV / resting-HR but leaves `recovery` null until enough history accumulates — expected, not a bug.
- **WHOOP 4 SpO₂ / skin-temp** historical records carry raw PPG counts (`red`/`ir`) and a raw temp int,
  not calibrated `%`/`°C`; the engine does not derive daily SpO₂ / skin-temp from them, so those daily
  fields stay null on a 4.0 import.

See `Tools/linux-capture/README.md` for the capture/export side that produces these files.

---

## Analytics

`com.noop.analytics.Analytics.kt` ports the pure math from `Strand/App/AppModel.swift`:

- **`Hrv.rmssd(rr)`** — root-mean-square of successive R-R differences (ms); returns `0.0` for
  fewer than two intervals (matches the Swift `rr.count >= 2` guard).
- **`Zones.zone(hr, hrMax)`** — the `pct = hr/hrMax` ladder (`≥0.9→5, ≥0.8→4, ≥0.7→3, ≥0.6→2,
  else 1`), with a fallback to zone 1 when `hrMax ≤ 0`. `Zones.hrMaxTanaka(age)` = `round(208 − 0.7·age)`.
- **`IllnessWatch.evaluate(days)`** — compares the last ~2 days against a ~28-day baseline ending 3
  days ago across resting HR, HRV, skin-temp deviation, and respiration; surfaces a banner when 2+
  anomalies fire. Requires ≥14 days of history. The Swift `behavior.illnessWatch` UI toggle is
  intentionally omitted from this pure function — the caller decides whether to run it.

`AnalyticsTest.kt` locks these against known vectors. The heavier `StrandAnalytics` package
(`RecoveryScorer`, `StrainScorer`, `SleepStager`, `CorrelationEngine`, `Baselines`, …) is ported so
the Android results match macOS; keep each module in parity against the Swift sources and extend the
matching JVM unit tests as the math evolves. Strain computes from HR on **all** strap families —
there's no hard 5.0/MG gate — but because 5.0/MG HR is currently sparse, those scores build slowly
(and sit near 0 without sustained wear) until the deeper 5.0/MG offload is fully reverse-engineered.

---

## Compose UI

The UI is Jetpack Compose (Material 3). The theme resources (`res/values/colors.xml`, `themes.xml`
with `Theme.NOOP`, `strings.xml` with `app_name = "NOOP"`), `MainActivity`, and the screens are all
in place. The dependency set in `app/build.gradle.kts` is wired for Compose (BOM `2024.06.00`,
Material 3, Material icons extended, `activity-compose`, `navigation-compose`,
`lifecycle-viewmodel-compose`) and Coroutines.

The screens follow the reference app's information architecture (`Strand/Screens/`): Today, Live,
Sleep, Trends, Stress, Workouts, Compare, Insights, Metric Explorer, Data Sources, and Settings.
`StrandDesign` (palette / components / charts) is the spec for tokens and chart styles,
re-expressed as a Compose theme — colors come from `Theme.NOOP`, never hardcoded. When extending the
UI, keep that parity.

---

## Permissions and the no-internet posture

The manifest is deliberately minimal and **declares no `INTERNET` permission** — nothing leaves the
device. Permissions, straight from `android/app/src/main/AndroidManifest.xml`:

| Permission | API range | Why |
| --- | --- | --- |
| `BLUETOOTH_SCAN` (`neverForLocation`) | 31+ | scan for the strap; opt out of location coupling |
| `BLUETOOTH_CONNECT` | 31+ | connect / bond / GATT I/O |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` | ≤30 | legacy install-time BLE perms |
| `ACCESS_FINE_LOCATION` | ≤30 | required for BLE scans on API 26–30 only |
| `FOREGROUND_SERVICE` | all | keep the link alive while backgrounded |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | 34+ | typed foreground service for the GATT connection |
| `<uses-feature bluetooth_le required="true">` | — | BLE is mandatory hardware |

On API 31+ you must **request `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` at runtime** before scanning
or connecting. `android:allowBackup="false"` and the `data_extraction_rules.xml` keep the local DB
out of cloud/device-transfer backups — consistent with "your data stays on your device."

---

## Verification checklist

The Android client is built, released, and validated on real WHOOP 4.0 hardware (with live HR on
5.0/MG), so the build/static, protocol-parity, storage-parity, and core 4.0 BLE items below are
**confirmed** (checked off). Treat this as an ongoing **parity gate**: the items left unchecked are
the genuinely-open ones — chiefly full WHOOP 5.0 / MG deep-score validation — and any new item
should be re-verified against a real build, a real device, and a real strap before it's ticked.

**Build & static**

- [x] Gradle wrapper committed (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.{jar,properties}`).
- [x] Entry points present: `com/noop/NoopApplication.kt`, `com/noop/ui/MainActivity.kt`,
      `app/proguard-rules.pro`.
- [x] `./gradlew :app:testDebugUnitTest` is green (analytics vectors).
- [x] `./gradlew assembleDebug` produces `app-debug.apk`.
- [x] `./gradlew assembleFullRelease` / `assembleDemoRelease` succeed with R8 full mode + resource shrinking.
- [x] APK declares **no `INTERNET` permission** (`aapt dump permissions app-debug.apk`).

**Protocol parity (JVM, no device)**

- [x] `Crc.crc8/crc32/crc16Modbus` match the Swift `FramingTests` vectors bit-for-bit.
- [x] `verifyFrame` + `Reassembler` reproduce `FramingTests` / `ReassemblerTests`.
- [x] `parseFrame` (4.0) + `parseFrame(family: whoop5)` reproduce `ParityTests` /
      `StreamsParityTests` / `HistoricalStreamsParityTests` against the same fixtures.
- [x] `WhoopCommand.frame(seq, payload)` reproduces the macOS command bytes (e.g. CLIENT_HELLO and a
      known `GET_BATTERY_LEVEL` frame).
- [x] The bundled `whoop_protocol.json` asset is the same file as the Swift resource (same
      `version`, enum counts: PacketType 16, CommandNumber 77).

**Storage parity (JVM/instrumented)**

- [x] Room-generated `CREATE TABLE`/index SQL matches `Database.swift` for every ported table
      (column names, types, composite PKs, the `metricSeries` index).
- [x] `OnConflictStrategy.IGNORE` dedupes on the natural keys exactly like the GRDB upserts.
- [x] `payloadJSON` for a decoded event equals the Swift `StreamStore.encodePayload` output
      (sorted keys, `event`/`event_timestamp` removed).

**BLE on a real device with a real strap** — WHOOP 4.0 confirmed; WHOOP 5.0 / MG live-HR confirmed,
deeper scores still being reverse-engineered.

- [x] Runtime permission flow: `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` granted on API 31+.
- [x] Scan finds the strap by the family service UUID (4.0 `61080001-…`, 5.0 `fd4b0001-…`).
- [x] Connect → discover services → discover the family characteristics.
- [x] **Bond via the single confirmed write** of `GET_BATTERY_LEVEL` to `…0002`
      (`onCharacteristicWrite(GATT_SUCCESS)`).
- [x] CCCD `0x2902` descriptor write enables notifications on `…0003/0004/0005`, `0x2A37`, `0x2A19`.
- [x] GATT operation queue prevents dropped writes (one in flight at a time).
- [x] Connect handshake runs **exactly once** per connection (the `connectHandshakeDone` guard) —
      no `hello`/`SET_CLOCK` re-blast mid-offload.
- [x] Standard HR (`0x2A37`) yields plausible HR (30–220 bpm) and R-R intervals (4.0 + 5.0/MG).
- [x] `SET_CLOCK` (8-byte payload) latches; `GET_CLOCK` (empty payload) returns a clock correlation.
- [x] `sendR10R11Realtime [0x00]` stops the ~2/s type-43 raw flood.
- [x] Historical offload (`sendHistoricalData [0x00]`) streams HISTORY_START → type-47 →
      HISTORY_END (acked via `historicalDataResult [0x01]+endData`) → HISTORY_COMPLETE (WHOOP 4.0).
- [ ] WHOOP 5.0 / MG: full offload + **deep-score** parity (recovery / strain / sleep) on a real
      5.0 strap — live HR confirmed; the derived scores are still being reverse-engineered.
- [x] Foreground service keeps the link alive while backgrounded.
- [x] Decoded rows land in Room and survive an app restart.

---

## Credits

The Android client re-implements protocol and behavior built on prior community
reverse-engineering and interoperability work:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 BLE protocol; the `WhoopProtocol` / `WhoopStore`
  packages the Kotlin protocol and storage ports follow.
- **`b-nnett/goose`** — WHOOP 5.0 / MG BLE protocol (service family `fd4b0001-…`, CRC16-Modbus
  header, CLIENT_HELLO, "puffin" packet types) that the WHOOP-5 path is ported from.

See [`../ATTRIBUTION.md`](../ATTRIBUTION.md) for full detail. NOOP contains no WHOOP proprietary
code, firmware, logos, or assets, operates only with the user's own device and data, and is **not a
medical device**.
