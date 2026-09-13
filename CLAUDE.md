# CLAUDE.md — working on NOOP

Guidance for anyone (human or AI agent) submitting a pull request. This is the high-signal map;
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) is the full guide (BLE safety contract, design-system
rules, add-a-metric/screen/command recipes), [`docs/BUILD.md`](docs/BUILD.md) covers signing/pairing,
and [`docs/IOS.md`](docs/IOS.md) covers the iOS target. Read this first; follow the links for depth.

## What NOOP is (and the hard scope limits)

NOOP is an **offline-by-default, on-device** companion app for WHOOP 4.0 and 5.0/MG straps (with
**experimental** Oura support in the tree — gated behind `ExperimentalBrand`, not a shipped supported
strap). It pairs over Bluetooth, stores everything in on-device SQLite, and computes recovery / strain
/ HRV / sleep locally. There is **no NOOP-operated server, no account, no cloud dependency, no
telemetry**, and the project stays **anonymous** (iOS/Android ship build-from-source / sideload, not
via the App Store). Issue #1314 permits one narrow exception: a default-off Experimental client may
export data one way to an HTTP(S) endpoint the user owns and configures. It must remain outside strap
sync, never read data back, and ship no receiver or hosted service in this repository.

These are hard constraints, not preferences. A PR is out of scope if it:
- adds a server, account, cloud dependency, or sends data off-device without the explicit user export
  boundary in [`docs/SCOPE.md`](docs/SCOPE.md) (including #1314's one-way self-hosted push);
- adds analytics/telemetry/crash-reporting that phones home;
- adds WHOOP firmware, decompiled app code, logos/assets, or any DRM circumvention. NOOP is
  **clean-room interoperability** with hardware the user owns — keep it that way. (That bars
  *implementations* and literals, not every fact learned from one: a protocol offset may be
  re-derived with attribution as an unvalidated candidate — see the "facts vs code" bullet in
  [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) before telling a contributor no.)

Licensing: by opening a PR you agree your contribution is under the repo's
[PolyForm Noncommercial 1.0.0](LICENSE) license.

## Architecture at a glance

Core logic lives in **cross-platform Swift packages**; each platform is a thin app layer over them.
The **macOS app is the reference implementation**; **Android is a full shipped app**; **iOS is a
build-from-source target** folded into the same repo.

| Layer | Path | What lives here |
|---|---|---|
| Protocol (pure) | `Packages/WhoopProtocol`, `Packages/OuraProtocol` | BLE frame parse, CRC, command/event/packet decode. **No CoreBluetooth.** Builds on Linux; also builds the `whoop-decode` CLI. |
| Storage | `Packages/WhoopStore` | GRDB/SQLite persistence: migrations, streams, caches. |
| Analytics (pure) | `Packages/StrandAnalytics` | HRV / recovery / strain / sleep / correlation math. Database-free. |
| Import | `Packages/StrandImport` | WHOOP CSV + Apple Health importers. |
| Design system | `Packages/StrandDesign` | SwiftUI palette / components / charts. |
| macOS + shared app | `Strand/` (scheme **Strand**, product `NOOP`, macOS 13+) | `BLE/` (CoreBluetooth), `Collect/`, `Data/` (Repository), `Screens/`, `App/` (`RootView`/`ContentView` = sidebar shell). Shared with iOS where a file isn't macOS-only. |
| iOS-only app | `StrandiOS/` (scheme **NOOPiOS**, iOS 17+), `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*` | `StrandiOSApp` (@main), `RootTabView` (the iOS tab shell — no macOS analogue), iOS widgets, watch app. |
| Android app | `android/` (Kotlin, Compose, Room; flavors `Full`/`Demo`) | `com.noop.{ble,collect,data,ingest,analytics,protocol,ui,widget,…}` — mirrors the Swift layering with its own reimplementations. |

`project.yml` is the **XcodeGen source of truth**; `Strand.xcodeproj/` is generated — never hand-edit
or commit it. Re-run `xcodegen generate` after adding/removing files or editing `project.yml`.

**Where new code goes:** the more "wire-level" (bytes) or "math-level" a change is, the deeper into
`Packages/` it belongs — and the more it must be covered by a `swift test` that runs with no app, no
strap, no CoreBluetooth. Never add `import AppKit` / `import UIKit` / `import CoreBluetooth` under
`Packages/`; guard framework code with `#if canImport(AppKit)` / `#elseif canImport(UIKit)`.

## The cross-platform parity contract (the #1 rule)

Android is an independent reimplementation of the same logic, **not** a port that shares code with
Swift. So:

- **Analytics and stored data must be byte-identical across Swift and Kotlin.** If you change a
  decoder, an analytics formula, a migration, or a stored value on one platform, change the twin on
  the other in the same PR (or explicitly call out why not). "It's Compose vs SwiftUI" is *not* a
  license to let the numbers diverge.
- **Verify byte-identical by oracle, not by eye.** Extract the pure helper, compile the Swift twin
  standalone (`swiftc -O twin.swift main.swift -o t && ./t`) over the whole input space or a spread of
  cases, and paste that stdout verbatim as the expected literal in the Kotlin test. Reading the two
  implementations side by side does not catch what this does: it found a Swift helper trimming its input
  where the Kotlin one only checked blank-ness — invisible in review, and it would have surfaced as two
  field logs that disagreed. Note the oracle only guards the direction it is written in; a matching test
  on the other side is what stops Swift drifting.
- **UI parity is feature-level, not pixel-level.** SwiftUI Charts vs Compose Canvas legitimately
  differ; the *behavior* and the *data* must not.
- **Cross-platform hashes/dedup keys must use a platform-neutral algorithm** (e.g. FNV-1a over UTF-16
  code units) — never `hashValue` (Swift randomizes it) or Kotlin `hashCode` if the value crosses the
  `.noopbak` boundary.
- **The `.noopbak` backup whitelist is a byte-identical contract.** `BackupSettings.swift`
  (`Packages/WhoopStore`) and `BackupSettingsCodec` (`android/…/data/BackupSettings.kt`) must carry
  the same canonical keys + JSON kinds. Only Int/Double/String cross the wire — no dates/objects.
- **Room (Android) and GRDB (iOS) migrations must agree** on the resulting schema. Column order in a
  Room `CREATE TABLE` must match the entity field order; pin migrations with tests.

## Build, test & CI — and what actually validates your change

**This is the part people get wrong.** Know exactly what covers your change before you claim it works.

### Prerequisites (toolchain & packages)
Versions are pinned by the repo — install these before the loops below:
- **JDK 17** — Android + Gradle (`sourceCompatibility`/`jvmTarget` are 17 in `android/app/build.gradle.kts`).
  Gradle **8.7** is provisioned by `android/gradlew`; don't install a system Gradle.
- **Android SDK** — `platform-tools`, `platforms;android-34`, `build-tools;34.0.0` (match `compileSdk` /
  build-tools in `android/app/build.gradle.kts`). Point Gradle at it via `android/local.properties`
  (`sdk.dir=…`, gitignored) or `$ANDROID_HOME`.
- **Swift toolchain ≥ 5.9** — the pure packages declare `swift-tools-version: 5.9`; a 6.x toolchain builds
  them. On **macOS** this ships with Xcode (also required for the app targets); on **Linux** use a
  swift.org toolchain.
- **Linux system packages** (a swift.org toolchain tarball does not bundle its build/runtime deps):
  `build-essential libc6-dev` — the C runtime / crt objects the linker needs; without them `swift build`
  fails at link with `cannot find Scrt1.o … -lc`. Plus `libncurses-dev libxml2 libcurl4 zlib1g-dev
  libedit2 pkg-config unzip`.
- **Android build-tools on non-x86-64 Linux (e.g. arm64):** Google ships `aapt2` / `d8` as **x86-64 only**,
  so resource processing dies with `aapt2 … Syntax error` / `Exec format error` on an arm64 host unless x86
  emulation is present — install `qemu-user-static binfmt-support` and the kernel runs them transparently.
  macOS and x86-64 Linux are unaffected.

### Fast local loops
```bash
# Swift packages (fastest; no Xcode, no strap):
cd Packages/WhoopProtocol && swift build && swift test     # also OuraProtocol
# Android JVM unit tests (run on Linux/macOS, no device):
cd android && ./gradlew testFullDebugUnitTest              # add --tests "com.noop.…" to filter
cd android && ./gradlew compileFullDebugKotlin             # compile the whole app module
# macOS app (needs Xcode on macOS):
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### What each CI job covers — and the gaps
| Workflow | Covers | Runner | Default state |
|---|---|---|---|
| `swift-packages.yml` | TWO jobs. `test`: `swift test` over **`Packages/**`** (WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, StrandDesign, NoopLocalAccess). `tools`: `swift build` + `swift test` over **`Tools/SleepBench`, `Tools/SleepPSG`, `Tools/Backfill`** — Backfill has no test target, so it is build-only. Path-filtered to those directories. | macos-15 | **active** |
| `app-build.yml` | Builds the **app targets** (`Strand` macOS + `NOOPiOS` iOS) **and runs `StrandTests`** on the macOS/`Strand` leg only — the iOS leg is compile-only. iOS leg needs **macos-26** (iOS 26 SDK / `glassEffect`). | macos-15 / macos-26 | **disabled** (on-demand) |
| `android.yml` | `assembleFullDebug` + `testFullDebugUnitTest` | ubuntu | **active**, path-filtered to `android/**` |
| `source-hygiene.yml` | Doc comments that bind to nothing (`Tools/doc_comment_lint.py`) | ubuntu | **active** |
| `i18n-coverage.yml` | Diff-scoped translation gate (`Tools/i18n_audit.py --ci`) | ubuntu | **active** |
| `tools-python.yml` | `unittest discover` over `Tools/` and `Tools/linux-capture` | ubuntu | **active**, path-filtered |
| `prune-stale-branches.yml` | Deletes branches whose PR merged or closed unmerged | ubuntu | **active**, weekly + dispatch |
| `fork-testing-build.yml` / `fork-release.yml` | Staging / release builds (apk + mac + ios) | — | on dispatch |

**The trap:** `swift-packages` does **NOT** compile the app targets. So if you touch **app-target
Swift** — anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` (Views,
`AppModel`, `BLEManager`, `Repository`, `RootTabView`, widget publish, …) — **no default CI validates
it**, because `app-build.yml` is disabled. A compile error there (e.g. `'self' used before all stored
properties are initialized`) will pass every green check and still be broken. If you change app-target
Swift, you MUST build the app yourself: `xcodebuild … build` locally, or run `app-build.yml` on demand.

### Local walls (things that will *not* build where you expect)
- **On Linux:** `WhoopProtocol` / `OuraProtocol` (pure) build & test with a bare toolchain. The
  GRDB-linked packages need the snapshot-enabled SQLite build in [`docs/BUILD.md`](docs/BUILD.md) — with
  it, all four build AND test: `StrandAnalytics` (1523), `WhoopStore` (439), `StrandImport` (249) and
  `NoopLocalAccess` (9). Without those flags they fail with `sqlite3.h not found` (GRDB's CSQLite). `StrandDesign`
  needs SwiftUI and is macOS-only. Android JVM unit tests **do** run on Linux.
  **None of this is CI-enforced** — `swift-packages.yml` is macOS-only, so Linux support is honour-system
  and a change can break it silently.
- **App targets** (`Strand`, `NOOPiOS`) need **Xcode on macOS**; `StrandTests` runs only under
  `xcodebuild … test` on macOS — locally, or via `app-build.yml`, which does run it on the `Strand` leg.
  Since that workflow is **disabled by default**, app-target tests are only as validated as your last
  on-demand dispatch: writing them is not the same as having run them.
- **BLE behavior cannot be CI- or Linux-tested.** Anything on the CoreBluetooth / offload / live-HR
  path (`Strand/BLE`, `Strand/Collect`, Android `com.noop.ble`) must be **validated on a real strap**;
  compile-success proves nothing about connection behavior. Say what you tested on hardware.

## Hard rules before you touch these areas

- **BLE (read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §BLE safety contract first):** never add
  destructive/write commands to hardware; CRC-gate every inbound frame; keep the connection path
  stable; no hardcoded hex frame bytes in app code — protocol facts live in the decoders/schema.
- **`didBond` is load-bearing well beyond the handshake — check every reader before you make a strap
  deliberately not bond.** At least three independent mechanisms treat "connected but never bonded" as a
  fault to be corrected: the bond watchdog bounces the link once its window expires, the #982 never-bonded
  detector counts self-drops toward pausing auto-reconnect, and the bond-refusal give-up latches on it.
  A change that legitimately leaves a strap unbonded — suppressing an unanswerable handshake, deferring
  one while an OS pairing is in flight — silently re-arms all of them, and each will undo the change a few
  seconds or a few drops later while reporting a cause that never happened (#1635). Not-bonding is only
  evidence of a fault when we were actually *trying* to bond.
- **A diagnostic may only assert what it can attribute.** Repeatedly in the #1635 investigation a line
  claimed more than it observed and sent the diagnosis backwards: a `GATT_*` status rendered through the
  `BluetoothStatusCodes` table (different enumeration, colliding small integers), a bond declared from a
  completion nobody checked the characteristic of, "we write WITH RESPONSE" printed before the code that
  decides whether to write at all, "the strap refused" for a local `SecurityException`, and a *persisted*
  refusal blaming a strap for a read that our own in-flight pairing broke. Prefer silence, or name the
  gap. Conversely, do not let a path go quiet: replacing a wrong line with no line removed the evidence
  that identified the bug. Gate per-connect readouts behind the Test Centre domain; leave rare-event
  evidence (a state transition, a mismatch) always-on, since it costs nothing when nothing happens and is
  what is missing when someone reports a problem without Test Centre enabled.
- **Device / strap model resolution:** map a registry `model` label to a family through the ONE
  canonical resolver (`DeviceFamily.forRegistryModel` on both platforms), never a scattered
  string compare — the wizard stores `"4.0"`, other paths `"WHOOP 4.0"`, and single-spelling checks
  silently miss straps. Reads must thread the registry's **active** strap id, not a raw BLE address.
- **`doc_comment_lint` reports at the wrong line on purpose — do not chase it.** The baseline is a
  *per-file count* of grandfathered sites, not a set of line numbers (deliberately: a line-keyed baseline
  goes stale constantly). So adding one new detached doc comment makes the file overflow its budget and
  the failures print against **other, pre-existing** sites — often nowhere near your edit. Look at what
  you just inserted, not at the lines it names. The usual cause is inserting a declaration directly above
  an existing one, which lands your code between that neighbour's doc block and the thing it documents:
  insert **above the neighbour's doc block**, or after the previous declaration's closing brace.
- **Design system is law:** UI uses only design tokens — `StrandPalette` / `StrandFont` / shared
  components on Apple, `Palette` / `Metrics` on Android. No hardcoded colors, fonts, or spacing.
- **Migrations:** add a versioned migration + a test; never mutate an existing migration. Watch for
  data-loss traps (window-wide deletes, backfill rewrites) — prefer additive/transactional changes.
- **Deriving a physiological signal from raw sensor data — validate against the artifact, not one
  match:** the WHOOP optical/motion buffers are fixed-N-samples-per-record, so autocorrelation/spectral
  methods can manufacture a peak at the record period that *looks* physiological and coincidentally
  matches the WHOOP app on a stable night — that's why the PPG→HR estimate (#194) was withdrawn. A
  single "matched WHOOP" night is **not** validation. Prove the method **tracks a varying input**
  (different subjects, or nights where the true value moves; for synthetic tests, recover *multiple*
  injected values, not one). Until it does, land it as **instrumentation** (decode + store + log the
  estimate beside the incumbent) or behind a **default-off Experimental toggle** — never make it the
  default or feed it a downstream gate (recovery, illness) on thin evidence. (WHOOP 4.0 motion is
  separately too sparse to reliably stage sleep or tell in-bed from out-of-bed — see #345.)

## iOS / Android specifics worth knowing

- **iOS is `NOOPiOS`**, not `Strand`. `ContentView`/`RootView` (the macOS sidebar) are excluded from
  iOS; the iOS shell is `RootTabView`. A file shared with macOS (`TodayView`, `Repository`, analytics)
  must keep compiling for **both** — check the `Strand` (macOS) build too when you edit shared files.
- **Android** is Compose + Room, flavors `Full` (real) and `Demo`. Profile/prefs live in
  SharedPreferences; the DB is Room. UI state uses a `mutate {}` recomposition-counter idiom in places.
- iOS/macOS deployment targets: macOS 13.0, iOS 17.0 (see `project.yml`).

## PR & commit conventions

- **One concern per PR.** Keep a protocol change, a schema migration, and a UI change separate.
- **Show your verification.** BLE → what you tested on hardware. Analytics → the method + a test.
  UI → confirms design tokens only. App-target Swift → that you compiled the app (CI won't).
- **Keep generated artifacts out of git** (`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`,
  DerivedData). Commit `project.yml`, not the generated project. `Package.resolved` is fine.
- **Cross-platform:** if the change applies to both platforms, do both (or say why not).
- **Versioning (SemVer):** bump `MARKETING_VERSION` in `project.yml` **and** `versionName` in
  `android/app/build.gradle.kts` together; build numbers increment independently. The parts are
  counters, not decimals (`2.0.10` follows `2.0.9`).
- **Voice:** docs/comments are neutral, third-person, project-voice. Keep upstream credits intact.
- **Release-note credits use GitHub handles (#736).** In a release's contributor section, credit
  **third-party** work by `@handle`, not by display name — a plain name is invisible to GitHub, so it
  neither notifies the contributor nor links to their profile. A display name may accompany the handle,
  but the handle is what makes the credit real: `Thanks to @tigercraft4 (Sleep/Health refactors),
  @digitalerdude (workout backfill), …`.
  - Credit both **merged PR authors** and the **issue reporters** whose reports drove a fix — a good bug
    report with a strap log is often the harder half.
  - **Only third-party contributors.** The maintainer's own handles (`@ryanbr` / `@Fanboynz`) are left
    out: self-credit adds noise and self-mentions notify nobody.
  - Collect the handles with **`Tools/release-contributors.sh <since-date|since-tag>`**, which lists every
    third-party merged PR and every issue *closed as completed* in the range, plus a ready credit line,
    with the maintainer's own handles and bot accounts filtered out. A tag argument is bounded at that
    tag's exact instant, so the previous release's work is not re-credited. Writing *what* each person
    contributed is still by hand — that's the judgement part; hunting logins is not. Its output is a work
    list to prune, not a finished line: a reporter whose issue is not worth calling out in the notes can
    be left to the closing "everyone who filed the reports behind these fixes". `Tools/release.sh` warns
    when the notes it is about to publish credit no `@handle`.

When in doubt, open an issue to coordinate first, and prefer the smallest change that's correct and
covered by a test that runs without a strap.
