# NOOP — Android

An **offline WHOOP companion** for Android. NOOP connects directly to a WHOOP 4.0
(and WHOOP 5.0) strap over Bluetooth Low Energy, reads heart rate, R-R intervals,
battery, and sensor data, and stores everything **locally** on the device. There is
no NOOP account, hosted server, or telemetry. Network access exists only for explicit,
default-off features such as the AI Coach and Experimental one-way push to an endpoint
the user owns.

This is an independent Kotlin / Jetpack Compose reimplementation of the macOS/iOS
reference app (`Strand/`, Swift). The protocol, framing, and BLE handshake are
translated from that hardware-verified implementation, not invented here, and kept in
byte-for-byte parity with it (see the repo root [`CLAUDE.md`](../CLAUDE.md)).

---

## Status

NOOP for Android is a **shipped app**, not a draft. It builds in CI (dependency-locked +
SHA-256-verified + Room KSP-validated), ships versioned releases, and runs on real devices
with real users against real **WHOOP 4.0 and 5.0/MG** straps.

**BLE work still needs real hardware, though — a compile proves nothing about the radio.**
The bond handshake (one confirmed write to the command characteristic), the realtime HR
stream, the historical (type-47) offload, and the haptic buzz can't be exercised in an
emulator. Any change on the CoreBluetooth/GATT, offload, or live-HR path must be validated
on a phone with Bluetooth **and** an actual strap — say what you tested on hardware. See the
**Verification checklist** at the bottom.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **JDK** | 17 | The build targets `jvmTarget = "17"`. JDK 17 ships inside recent Android Studio (Jellyfish / Koala) — use *Settings → Build Tools → Gradle → Gradle JDK → 17*, or install Temurin 17. |
| **Android SDK** | API 34 (compileSdk/targetSdk) | Install "Android 14 (UpsideDownCake)" + Platform-Tools via the SDK Manager. `minSdk` is 26 (Android 8.0). |
| **Android Studio** | New enough for Gradle 8.7 (Ladybug 2024.2+ / recent Koala) | The project pins Gradle **8.7** + AGP **8.5.2** via the checked-in wrapper. |
| **A physical device** | Android 8.0+ with BLE | An emulator has no Bluetooth radio — you cannot test the strap link on it. |
| **A WHOOP strap** | WHOOP 4.0 or 5.0/MG (both shipped/verified) | Required to exercise the protocol end-to-end. |

### Point Gradle at your SDK

Create `local.properties` in this `android/` directory (it is git-ignored):

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

Android Studio writes this for you automatically when you open the project.

---

## Toolchain versions (pinned)

These are fixed in the build files; keep them in lockstep if you upgrade:

- **Android Gradle Plugin** 8.5.2 · **Gradle** 8.7 (wrapper)
- **Kotlin** 1.9.24 · **KSP** 1.9.24-1.0.20 (KSP must always match the Kotlin version)
- **Compose Compiler** extension 1.5.14 (matched to Kotlin 1.9.24)
- **Compose BOM** 2024.06.00 · **Material3** (from the BOM)
- **Room** 2.6.1 · **coroutines** 1.8.1
- **minSdk** 26 · **compile/targetSdk** 34 · **JDK target** 17

### Updating dependencies safely

The resolved Android graph is committed in `app/gradle.lockfile`, and Gradle verifies downloaded
plugins, metadata, and artifacts against `gradle/verification-metadata.xml`. When changing a plugin,
library, BOM, or the Gradle wrapper:

1. Make the version change in the relevant build file.
2. Regenerate both security files with JDK 17:

   ```bash
   ./gradlew :app:dependencies --write-locks --write-verification-metadata sha256
   ```

3. Review the lockfile and verification-metadata diffs. Treat newly generated checksums as a
   trust-on-first-use prompt: confirm the coordinates and release from the publisher or repository;
   do not accept unexpected artifacts merely to make a build pass.
4. Exercise every shipped variant and the JVM tests before committing:

   ```bash
   ./gradlew assembleFullDebug assembleDemoDebug \
     testFullDebugUnitTest testDemoDebugUnitTest
   ./gradlew -PstagingRelease assembleFullRelease assembleDemoRelease
   ```

Never bypass verification or hand-edit the generated lockfile. For a wrapper upgrade, also obtain
the binary-distribution SHA-256 from Gradle's official checksum reference and regenerate the wrapper
JAR/scripts with the target Gradle version.

#### Platform-classified artifacts (why `aapt2` carries one entry per OS)

`com.android.tools.build:aapt2` ships a separate jar per host OS — `-linux.jar`, `-osx.jar`,
`-windows.jar` — and Gradle only ever resolves the one matching the machine it runs on. Step 2
above can therefore only record *that* host's variant, so the checked-in file reflects whichever
OS last regenerated it. CI runs on Linux, so a Linux-only file makes every macOS build fail at
`:app:processFullDebugResources`:

```
> Dependency verification failed for configuration ':app:detachedConfiguration2'
  One artifact failed verification: aapt2-8.5.2-11315950-osx.jar
```

The fix is **additive**: add the missing variant, never drop the one already there. This is the
one case where editing `verification-metadata.xml` by hand is correct rather than a bypass — the
checksum is still verified from the publisher before it is trusted, which is the whole point of
the file. Verify it against Google's published digest, not against the build error:

```bash
V=8.5.2-11315950
B=https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/$V
curl -sS "$B/aapt2-$V-osx.jar.sha256"            # Google's published digest
curl -sS -o /tmp/aapt2.jar "$B/aapt2-$V-osx.jar"
shasum -a 256 /tmp/aapt2.jar                     # must equal the line above
```

Only when those two agree, add the artifact beside the existing one, keeping the file's sorted
order (classifier jars before the `.pom`) so a later regeneration does not churn the diff.

Do **not** paste the "actual" checksum out of Gradle's failure report: that value is precisely
what verification is challenging, so trusting it defeats the check. To confirm the method itself
is sound, run the same two commands against `-linux.jar` — they should reproduce the `-linux`
checksum already committed in the file.

---

## Build & run

```bash
cd <your-noop-clone>/android

# If intentionally regenerating the checked-in wrapper, use the pinned version + official checksum.
./gradlew wrapper --gradle-version 8.7 \
  --gradle-distribution-sha256-sum 544c35d6bd849ae8a5ed0bcea39ba677dc40f49df7d1835561582da2009b961d

# Compile the real ("full" flavor) debug APK:
./gradlew assembleFullDebug

# Install onto a connected, USB-debugging-enabled device:
./gradlew installFullDebug

# Or simply open this folder in Android Studio and press Run.
```

The debug APK lands at `app/build/outputs/apk/full/debug/app-full-debug.apk`. (There are two
flavors — `full` = the real app, `demo` = preloaded synthetic data; substitute `Demo` for
`Full` to build that one.)

> **About the wrapper:** `gradle-wrapper.jar`, both wrapper scripts, and the wrapper properties are
> checked in. The properties pin the Gradle distribution checksum, while CI validates the wrapper
> JAR. Do not regenerate only one part of the wrapper or substitute an unreviewed binary.

---

## Project layout

```
android/
├── settings.gradle.kts          # rootProject "NOOP", includes :app
├── build.gradle.kts             # root — plugin versions (apply false)
├── gradle.properties            # AndroidX on, JVM args
├── gradlew / gradlew.bat        # checked-in wrapper launchers
├── gradle/verification-metadata.xml # SHA-256 allowlist for plugins + dependencies
├── gradle/wrapper/…             # checked-in Gradle 8.7 wrapper + distribution checksum
└── app/
    ├── build.gradle.kts         # android{} config + dependencies + locking policy
    ├── gradle.lockfile          # exact resolved versions for every Android variant
    ├── proguard-rules.pro
    └── src/main/
        ├── AndroidManifest.xml  # BLE permissions, MainActivity launcher
        ├── res/                 # theme, colors, strings, adaptive launcher icon
        └── java/com/noop/
            ├── NoopApplication.kt
            ├── protocol/        # enums, Crc, Framing, Reassembler, DeviceFamily
            ├── ble/             # WhoopBleClient (BluetoothGatt + scanner), collect + offload
            ├── data/            # Room entities, DAO, database, repository, backup
            ├── analytics/       # HRV, recovery, strain, sleep staging, auto-workout, baselines, …
            ├── ingest/          # CSV / Apple Health / Health Connect import + export
            ├── oura/ · polar/   # experimental non-WHOOP source decoders
            ├── alarm/ · notif/ · location/ · update/ · widget/ · testcentre/ · ai/
            └── ui/              # NoopTheme, MainActivity, AppViewModel, Compose screens, NavHost
```

Root package: `com.noop` · application id: `com.noop.whoop`. Debug builds append `.debug`;
the `demo` flavor appends `.demo`; the fork staging release appends `.staging` — so all
install side-by-side.

---

## Permissions & why

NOOP requests the platform permissions its local features need. `INTERNET` supports only
explicit, default-off network features (the AI Coach and Experimental self-hosted push):

- **`INTERNET`** — lets those opt-in clients reach the endpoint the user selected. It is an
  install-time capability, not evidence of background telemetry; neither feature runs until
  configured.

- **`BLUETOOTH_SCAN`** (`neverForLocation`) + **`BLUETOOTH_CONNECT`** — Android 12+ (API 31+)
  runtime permissions. `neverForLocation` lets us skip the location grant on modern Android
  because we never derive physical location from scan results.
- **`BLUETOOTH` / `BLUETOOTH_ADMIN`** (`maxSdkVersion=30`) — the legacy install-time perms for
  Android 8–11.
- **`ACCESS_FINE_LOCATION`** (`maxSdkVersion=30`) — required to run a BLE scan on Android 6–11
  only; not requested on API 31+.
- **`FOREGROUND_SERVICE`** (+ `FOREGROUND_SERVICE_CONNECTED_DEVICE` on API 34) — to keep the
  link alive while collecting/offloading in the background.

On Android 12+ the app must **request the BLUETOOTH_SCAN / BLUETOOTH_CONNECT runtime
permissions at first launch** before scanning — handle this in the UI permission flow.

---

## BLE contract (must match the strap)

These come from the hardware-verified reference (`Strand/BLE/BLEManager.swift`)
and are the source of truth for the BLE layer:

| Item | Value |
|---|---|
| WHOOP 4 custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` |
| → command write char | `61080002-…` (CMD → strap) |
| → command notify char | `61080003-…` (responses) |
| → event notify char | `61080004-…` (events) |
| → data notify char | `61080005-…` (fragmented data) |
| WHOOP 5 custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Standard HR service / char | `0x180D` / `0x2A37` (HR + R-R, works **unbonded**) |
| Battery service / char | `0x180F` / `0x2A19` (percent) |
| **Bond** | exactly **one confirmed (`writeWithResponse`) write** to the command characteristic — the reference uses `GET_BATTERY_LEVEL`. Its completion callback = bonded. |

The framing envelope (verified): `0xAA`, u16 LE length, CRC8(length bytes),
`[type=35][seq][cmd][payload]`, CRC32 LE. Fragments arriving on the notify
characteristics are reassembled before routing.

---

## Verification checklist

Work top-to-bottom. Items above the line need only a phone; items below the line need a
phone **and** a WHOOP strap.

**Build (phone or emulator):**

- [ ] `./gradlew assembleFullDebug` compiles with no errors.
- [ ] App installs and launches to the main screen without crashing.
- [ ] Dark NOOP theme renders (surfaceBase `#060A08`, accent `#18C98B`); no white flash on launch.
- [ ] Navigation between the main tabs works (Today / Sleep / Trends / Coach / Settings, etc.).
- [ ] Runtime BLE permission prompt appears on first launch (Android 12+) and is handled.

**On real hardware (phone + WHOOP strap):**

- [ ] Scan discovers the strap by the WHOOP 4 service UUID and connects.
- [ ] **Bond succeeds** — one confirmed write to the command characteristic completes without error.
- [ ] Standard HR (`0x2A37`) streams a plausible heart rate (30–220 bpm) and R-R intervals.
- [ ] Battery (`0x2A19`) reports a sane percentage.
- [ ] Realtime HR toggle starts/stops the custom REALTIME stream.
- [ ] Historical (type-47) offload runs after connect and persists rows to Room.
- [ ] Wrist-on / wrist-off and charging events update `LiveState`.
- [ ] `buzz()` (RUN_HAPTICS_PATTERN, patternId 2) makes the strap vibrate.
- [ ] Reconnect after walking out of range / toggling Bluetooth resumes streaming.
- [ ] After a session, HRV (RMSSD), zones, and any daily metrics compute from stored data.

**Privacy sanity check:**

- [ ] With AI Coach and self-hosted push unconfigured, confirm no HTTP request is made during
      launch, BLE collection, offload, analytics, or normal navigation.

---

## Notes for contributors (BLE)

- The BLE layer is the highest-risk part. Android's `BluetoothGatt` is callback-based and
  serializes GATT operations differently from CoreBluetooth — queue writes/reads and wait
  for each callback before issuing the next, or operations will be silently dropped.
- "Bond" here means the app-level confirmed-write handshake described above, **not**
  necessarily Android OS pairing (`createBond()`); follow the reference's just-works flow.
- Keep all timestamps and CRC math byte-exact against the Swift reference — protocol bugs
  surface as "the strap won't serve data", not as crashes.
