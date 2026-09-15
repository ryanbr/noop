# Device-driver architecture — pluggable live sources

**Status:** Phase 1 implemented on `feat/multi-device-foundations` (`LiveHRSource`/`LiveHrSource`
protocol + coordinator collapse, both platforms; macOS app compiles, Android awaits a local/CI compile).
Companion to
[`DEVICE_SUPPORT_ROADMAP.md`](DEVICE_SUPPORT_ROADMAP.md), which records the *per-brand protocol facts*
(what each device exposes and how to reach it). This file covers the *internal architecture*: how a new
brand becomes a **recipe** instead of bespoke code threaded through the coordinator on both platforms.

North star is unchanged: **WHOOP is primary and must never regress.** Everything here is a refactor of
the already-shipped experimental multi-source tier — same behaviour, less friction to extend.

## The problem: adding a device is bespoke, four times over

Today a live non-WHOOP source is one of four concrete classes the coordinator holds as **typed
optionals** and routes to through a **hand-maintained switch**:

- `Strand/BLE/SourceCoordinator.swift` holds `standardSource` / `ftmsSource` / `huamiSource` /
  `ouraSource` (four `var … ?`), a `switch sourceKind { case .ftms / .huami / .oura / default }`, four
  near-identical `startXxxSource(id:)` methods, and a `tearDownNonWhoopSource()` that nils all four.
- Each new brand therefore touches, **on both platforms**:
  1. `ExperimentalBrand` — a recognition `case` (name-substring → brand);
  2. `SourceKind` — usually a new kind;
  3. a whole new `XxxHRSource` class (~150–450 lines, its own `CBCentralManager`);
  4. `SourceCoordinator` — a new stored optional, a `startXxxSource`, a `switch` arm, a teardown line;
  5. wizard/UI wiring.

Steps 1, 3, and 5 are irreducible (recognition + the actual driver + honest UI are real per-device
work). **Step 4 is pure boilerplate that grows O(n) with every brand** — that is what this refactor
removes.

## The shared surface is already uniform

All four existing sources expose an identical control surface (verified in-tree):

| Method | Standard | Huami | FTMS | Oura |
|---|---|---|---|---|
| `func scan()` | ✅ | ✅ | ✅ | ✅ |
| `func connect(_ id: UUID)` | ✅ | ✅ | ✅ | ✅ |
| `func stop()` | ✅ | ✅ | ✅ | ✅ |

They also share the same construction wiring — `live: LiveState`, a `persist:` closure, a `log:`
diagnostic sink, and an `onBattery:` callback — differing only in source-specific extras (Oura adds
`ringGen` / `authKey` / `adoptIntent`). The coordinator, crucially, **only ever calls `scan` /
`connect` / `stop`** on the source it holds. The richer `@Published` state (`discovered`, `scanning`,
`batteryPct`, `needsPairing`, `adoptPhase`) is consumed by the **wizard/pairing UI**, not by the
coordinator's active-source management — so it stays a separate concern and does **not** belong in this
protocol.

## Proposal: a `LiveHRSource` protocol + a factory

### 1. The protocol (minimal, exactly the coordinator's needs)

```swift
/// A non-WHOOP live BLE source the SourceCoordinator can run as the single active source.
/// Deliberately minimal: the coordinator only starts, targets, and stops. All richer state
/// (discovered peripherals, scanning flag, battery, pairing prompts) stays on the concrete
/// type for the wizard/UI to observe — it is not part of this contract.
@MainActor
protocol LiveHRSource: AnyObject {
    func scan()
    func connect(_ id: UUID)
    func stop()
}
```

`StandardHRSource`, `HuamiHRSource`, `FTMSSource`, `OuraLiveSource` conform **without a single line of
logic changing** — they already have these three methods. Conformance is a one-line
`extension StandardHRSource: LiveHRSource {}` each (methods are already `public`).

### 2. The coordinator collapses

Four optionals + a switch + four `startXxxSource` + a four-line teardown become:

```swift
/// The one non-WHOOP source currently live (nil when WHOOP-active or idle). Exactly one at a time.
private var activeSource: (any LiveHRSource)?

private func switchToStrap(id: String) {
    // …unchanged WHOOP-pause / churn-guard logic…
    tearDownNonWhoopSource()
    let source = makeSource(for: id)           // factory replaces the per-kind switch
    if let pid = peripheralId(for: id), let uuid = UUID(uuidString: pid) {
        source.connect(uuid)                   // connect-by-identifier, unchanged (#421)
    } else {
        source.scan()
    }
    activeSource = source
    activeStrapId = id
    onStrap = true
}

private func tearDownNonWhoopSource() {
    activeSource?.stop()
    activeSource = nil
}

/// Build the isolated source for a device id from its registered `sourceKind`. The ONE place
/// that maps a kind → a concrete driver; adding a brand adds one arm here, nothing else in the
/// coordinator. Each arm keeps its existing bespoke construction (persist/log/onBattery, plus
/// Oura's ringGen/authKey/adoptIntent).
private func makeSource(for id: String) -> any LiveHRSource {
    switch sourceKind(for: id) {
    case .ftms:  return makeFTMS(id: id)
    case .huami: return makeHuami(id: id)
    case .oura:  return makeOura(id: id)
    default:     return makeStandard(id: id)
    }
}
```

Note the switch does **not** fully disappear — a `sourceKind → concrete init` factory is irreducible
because each driver's constructor differs (Oura needs a key from the Keychain, etc.). What disappears is
the **duplication**: four stored optionals → one; four teardown lines → one; the start-methods keep only
their genuinely-distinct construction and lose the shared connect/scan/store bookkeeping.

### 3. Oura's extra surface stays off the hot path

`OuraLiveSource` is published (`@Published private(set) var ouraSource`) because the adopt-consent UI
observes `adoptPhase`. Keep a **separate** typed reference for that (`private(set) var ouraSource:
OuraLiveSource?`) set inside `makeOura`, alongside the protocol-typed `activeSource`. The coordinator's
lifecycle logic uses `activeSource`; the adopt UI keeps its typed handle. `tearDownNonWhoopSource()`
nils both. This preserves the exact adopt flow (`requestOuraAdopt` / `pendingAdoptDeviceId`) with no
behaviour change.

## Cross-platform parity (rule #1)

The Android coordinator (`android/app/src/main/java/com/noop/ble/…`) mirrors the same shape and gets the
**same** refactor in the **same PR**:

- Kotlin `interface LiveHrSource { fun scan(); fun connect(id: …); fun stop() }`.
- The Android source-coordinator's per-kind fields/branches collapse to one `activeSource` + a
  `makeSource(kind)` factory, identical control flow to Swift.
- No stored value, dedup key, or `.noopbak` field changes — this is an **in-memory runtime refactor
  only**, so there is no migration and no schema/backup-contract surface. (Call this out explicitly in
  the PR: parity here is *behavioural*, and the "numbers" — analytics, stored samples — are untouched by
  construction.)

### Parity checklist (for the PR)
- [ ] `LiveHRSource` (Swift) ⇄ `LiveHrSource` (Kotlin): same three methods, same semantics.
- [ ] Coordinator control flow identical: same churn guards, same WHOOP-pause edge, same
      connect-by-identifier-else-scan fallback (#421), same single-active-source invariant.
- [ ] Oura adopt-consent path unchanged on both (`adoptIntent` one-shot, key install still consent-gated).
- [ ] No change to `SourceKind` values, `PairedDevice`/registry rows, persisted samples, or backup keys.
- [ ] Existing driver unit tests still green on both platforms (they test the drivers, not the wiring).

## What validates this change

Per [AGENTS.md](../AGENTS.md), know the coverage before claiming it works:

- **`swift test` (`Packages/**`)** does **not** cover this — the coordinator and drivers live under
  `Strand/BLE`, i.e. **app-target Swift with no default CI** (`app-build.yml` is disabled). So:
  - Compile the **macOS app locally**: `xcodegen generate && xcodebuild -project Strand.xcodeproj
    -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
  - Compile the **Android app locally**: `cd android && ./gradlew compileFullDebugKotlin` +
    `./gradlew testFullDebugUnitTest`.
- **BLE behaviour cannot be CI- or Linux-tested.** Because this is a *structural* refactor with the
  driver logic byte-identical by construction, the risk is low — but the live path still wants **one
  on-strap smoke test** before merge: pair a WHOOP (confirm zero regression — the coordinator is a no-op
  for the single-WHOOP user) and one generic HR strap, switch active device both ways, confirm live HR
  streams and stops cleanly. State exactly what was tested on hardware in the PR.

## Scope guardrails (unchanged NOOP constraints)

- **Clean-room only.** Recognition stays name-substring (see `ExperimentalBrand`); no decompiled app
  code, no vendor firmware, no DRM circumvention. Deep decoders are re-derived, never GPL-copied — see
  `DEVICE_SUPPORT_ROADMAP.md` and `BLE_REVERSE_ENGINEERING.md`.
- **Offline, on-device, anonymous.** No account, no cloud, no telemetry. Cloud "import lanes" for
  Oura/Fitbit remain off-by-default and out of scope for this refactor.
- **Honest capability.** A brand with no open live stream (Oura live, Fitbit) must route to file import,
  never fake a connection or fabricate a value. The protocol does not change that stance.
- **Design tokens only** for any UI touched.

## Sequencing

1. **Phase 1 — this refactor (one PR).** `LiveHRSource`/`LiveHrSource` protocol + coordinator collapse,
   both platforms, no behaviour change. Enables everything below.
2. **Phase 2 — brand facts become a table (done).** The live-strap space is already broadly covered
   (standard 0x180D straps + Huami + Garmin broadcast + Oura), and Fitbit has no open live stream (it is
   an import lane, Phase 3) — so the highest-leverage groundwork was to make *recognising* a brand a
   table row, not to bolt on one more driver. `DeviceBrandCatalog` (`Packages/WhoopStore` +
   `android/…/data`) is now the single source of truth for advertised-name → `{brand, sourceKind,
   idPrefix, canStreamLiveHR, isExperimentalTier}`. It replaced three duplicated `brandGuess` copies
   (Swift) + one (Kotlin) and the token list inside `ExperimentalBrand`, which is now a thin typed view
   over the catalog. Pinned by pure tests on both platforms. **Follow-up:** fold the wizard's
   `DeviceType` → registration mapping (stored brand string, id-prefix, sourceKind) through the catalog
   too — today it still branches on `DeviceType`.
3. **Phase 3 — generalized file import (already shipped).** `WearableExportImporter` /
   `FitbitExportParser` / `OuraExportParser` / `GarminExportParser` (+ Kotlin twins) already import a
   user's own Oura / Fitbit / Garmin data export (fully offline, no cloud) into the shared
   `WearableDailyRow` / `WearableSleepSession` day model, under a `*-import` source id, with tests green
   on both platforms. Fitbit specifically reads Google-Takeout `sleep-*` / `resting_heart_rate-*` /
   `steps-*` JSON. **Genuine remaining work is extension, not construction:** the Fitbit parser leaves
   HRV / SpO2 / breathing-rate / avg-HR `nil` (it does not fabricate them) — extending it needs the real
   Takeout file shapes for those signals. The deeper unbuilt lanes are the *live* ones in
   `DEVICE_SUPPORT_ROADMAP.md` (Polar PMD ECG/PPG, Xiaomi live-BLE sync), which would be the first real
   new drivers built on the Phase 1 `LiveHRSource` abstraction.

## On-strap smoke test — the Phase 1 merge gate

The Phase 1 refactor is byte-identical *by construction* (driver logic untouched, WHOOP-first isolation
and churn guards preserved), and it compiles on both platforms, but **BLE behaviour cannot be CI- or
Linux-tested** (`docs/CONTRIBUTING.md` §BLE). Run this once on real hardware before merging, and record
the result on the PR:

1. **Single-WHOOP zero-regression** (the default, dormant path): launch with only the WHOOP paired.
   Confirm it connects, bonds, and streams live HR exactly as before — the coordinator must issue no
   scan / disconnect / re-point (`activeSource` stays nil; it is a pure no-op for one WHOOP).
2. **WHOOP → generic strap**: pair a standard 0x180D strap (Polar / Wahoo / Coospo / Garmin HRM), make
   it active. Confirm the WHOOP link tears down and the strap streams live HR under its own device id,
   with battery + strap-log lines appearing where the WHOOP's do.
3. **Strap → WHOOP (back)**: make the WHOOP active again. Confirm the strap source stops cleanly and the
   WHOOP reconnects and resumes — no lingering strap stream, no double connection.
4. **Idempotence**: re-select the already-active device; confirm nothing churns (no reconnect flap).

If an experimental band (Amazfit/Huami or an Oura ring) is on hand, repeat 2–3 for it to exercise the
`makeSource` Huami/Oura arms; otherwise the standard-strap pass covers the abstraction's hot path.
