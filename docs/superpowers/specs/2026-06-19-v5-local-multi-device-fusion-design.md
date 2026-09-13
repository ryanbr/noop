# NOOP v5 — Local Multi-Device Fusion ("One Honest Health Record")

**Codename:** Strand · **Pillar:** Local multi-device fusion · **Status:** Design (not approved) ·
**Date:** 2026-06-19

> One thesis line: **NOOP fuses every band you own — WHOOP, Mi Band, Apple Health, Health Connect (and
> planned Polar / Garmin / Oura) — into one record ON YOUR DEVICE, picking the best signal per metric and
> showing you exactly where each number came from. The privacy-respecting inverse of cloud aggregators.**

This spec is the **arbitration policy + a unified "Your data, fused" view + conflict handling** on top of
plumbing that **mostly already exists**. It deliberately does *not* re-architect the source model. Most of
the work is policy, a new read-only fusion view, honest conflict UX, and a Kotlin-twin parity sweep.

---

## Goal & differentiation (why only NOOP)

Everyone with a WHOOP also has a phone (Apple Health / Health Connect) and often a second band (a Mi Band
for steps, a Polar for workout HR, an Oura for sleep). Today those sit in walled gardens. The market splits
two ways and **NOOP is the only thing in the third corner**:

| Approach | Who | What they do | The catch |
|---|---|---|---|
| **Single-vendor lock-in** | WHOOP, Oura, Garmin, Ultrahuman | One band, one app, one cloud | Won't read a competitor's band; your Mi Band steps are invisible |
| **Cloud aggregators** | Spike, Terra, Rook, Tryterra | Normalise many vendors' data | **Your raw biometrics flow through their servers** — the privacy cost of "one record" |
| **Local fusion (NOOP)** | — | Fuse many bands, best-signal-wins, **on device** | — |

**Why only NOOP can do this honestly:** the fusion runs entirely on the phone/Mac. Nothing leaves the
device — no account, no server normalisation tier, no third-party seeing your R-R intervals. We already
import WHOOP exports, Apple Health, Health Connect and Xiaomi/Mi Band **locally**; v5 turns those parallel
silos into **one resolved record with visible provenance and honest conflict handling**. A cloud aggregator
structurally cannot offer "nothing leaves the device" — that's their whole business model. A single-vendor
app structurally won't read the other bands. NOOP sits in the gap.

**The honest promise (and its limits, stated up front):**
- ✅ Best *available* signal per metric, with the source named on every number.
- ✅ Cross-checks the same metric across sources and **flags disagreement instead of hiding it**.
- ❌ NOT a clinical reconciliation. We don't claim our fused number is "correct" — we claim it's the
  best-sourced and fully transparent. Two bands disagreeing is shown, not silently averaged away.

---

## Data & signals used (already available vs new)

### Already in the codebase (reuse, don't rebuild)
- **`DeviceRegistry`** (`Strand/Data/DeviceRegistry.swift`, `android/.../data/DeviceRegistry.kt`) — the
  paired-device list + active device, over the synchronous `DeviceRegistryStore`. `PairedDevice` already
  carries `brand / model / sourceKind {liveBLE, historyBLE, cloudImport, fileImport} / capabilities:
  Set<Metric> / status`. **This is our source-of-truth registry.** v5 reads `capabilities` for arbitration.
- **`SourceCoordinator`** (`Strand/BLE/SourceCoordinator.swift`, Kotlin twin) — runs exactly one live BLE
  source at a time, WHOOP-first/zero-regression. Live fusion stays single-active-source (we are NOT
  proposing concurrent multi-radio streaming — see Open questions). v5 fuses the *stored* record, not the
  live radio.
- **The cross-source resolver** — `Repository.resolvedSeries` / `Repository.sourceCandidates` /
  `appleCompatibleKey` (`Strand/Data/Repository.swift` ~L547–656) and its **byte-identical Kotlin twin**
  in `WhoopRepository.kt` (~L572–745). This is the *existing* per-metric precedence engine: imported WHOOP
  > NOOP-computed > declared-compatible Apple Health / Health Connect. **v5 generalises this from a
  hardcoded waterfall into a capability-driven policy** (below).
- **`DailyMetricSource` + `vitalPriority` + `SourcedDailyMetric`** (Repository.swift L61–82) — per-row
  provenance tags (`whoopImport / noopComputed / appleHealth / localCache`) already drive the source-aware
  vital cards. v5 extends the enum to cover every source and surfaces it in the new fused view.
- **`DayOwnerResolver`** (`Packages/StrandAnalytics/.../DayOwnerResolver.swift`) — already picks the single
  device that *owns* a day's scored metrics (invariant: scores never mix sources). v5 reuses this verbatim
  for the day-level "which band is today's record from" badge.
- **`RepositoryFreshness`** (Repository.swift L84–98) — per-source coverage counts feeding the Data Sources
  "Freshness Pipeline" card. v5 generalises it to N sources.
- **Importers** — `AppleHealthImporter`, `XiaomiBandImporter`, `WhoopExportImporter`, `NutritionCsvImport`,
  `LiftingImporter` (`Packages/StrandImport`), and Android's `HealthConnectImporter`. Each writes under a
  distinct `deviceId`/source string. **v5 adds no new importer in MVP** — it fuses what these already store.
- **Per-source provenance UI** — `StatePill`, the Data Sources cards (`DataSourcesView.swift`,
  `DevicesScreen.kt`), `usedSources` captions in `CompareView`.

### New in v5
- A **capability/source arbitration policy** table (data, not code branches) keyed by metric × source.
- A **per-metric trust order** that is *capability-aware* rather than source-name-hardcoded (so adding
  Polar/Garmin/Oura later is a registry-capability change, not a resolver rewrite).
- A **cross-validation pass**: when two sources report the same metric for the same day, compute their
  delta and tag the resolved point with an **agreement state** (`agree / minorDelta / conflict`).
- A new read-only **"Your Data, Fused"** model + view (one screen per platform).
- No new *signals*. Everything is derived from the metrics the importers and the strap already write.

---

## On-device algorithm (grounded)

All of this is pure, deterministic, on-device. No network, no model, no account.

### 1. Per-metric source-of-truth ("best signal wins")
Generalise the existing `sourceCandidates` waterfall into a **capability-ranked** ordering. For a metric
`m` and the set of sources that hold data for the day, sort by a **trust tier** derived from *how that
source produced the metric*, then a stable source-priority tiebreak.

Trust tiers (lower = more trusted), grounded in what each device actually measures vs estimates:

| Tier | Meaning | Examples |
|---|---|---|
| 0 | **Direct dedicated sensor** for this metric | WHOOP R-R for HRV; a wrist-PPG band's steps; chest-strap HR for avg/max HR; ring temp for skin temp |
| 1 | **Derived on-device from raw** by NOOP | NOOP-computed recovery/strain/sleep from strap streams |
| 2 | **Phone aggregate** (Apple Health / Health Connect) of a declared-compatible quantity | phone resting HR, asleep_min |
| 3 | **Estimate / proxy** | strap step *estimate*; calories estimate |

The rule mirrors the metric-specific intuition already baked into the current code:
- **Steps** → the device that *actually counts them* wins (a wrist band's pedometer over the strap's
  estimate; today `noopComputedCanFillAppleMetric` already encodes "strap step estimate is a last resort").
- **HR (avg/max/resting)** → a chest strap or PPG wins; cross-validate against phone.
- **Skin temp** → redundancy: prefer the source with the finer scale; today's `skin_temp` daily column
  already exists.
- **Sleep** → the **best stager** wins. Imported WHOOP stages > NOOP-computed stages > phone sleep
  buckets (`asleep_min/deep_min/rem_min/core_min` aliases already in `appleCompatibleKey`).

Implementation = **extend, don't replace**: `sourceCandidates(forKey:preferredSource:)` keeps its exact
signature and current output for the WHOOP/Apple cases (so all existing tests stay green), but its body is
rebuilt to *consult a `MetricArbitrationPolicy` table* instead of `if preferredSource == …` branches. The
policy table is the single place a future Polar/Garmin/Oura source is registered.

### 2. Cross-validation (the honest part)
For each `(metric, day)` where **two or more candidates** have a value, compute the pairwise delta against
the winning value and classify:

- **agree** — within metric-specific tolerance (e.g. resting HR ±3 bpm, asleep_min ±20 min, steps ±10%).
- **minorDelta** — outside tolerance but within a "plausible measurement spread" band → show both, no
  alarm.
- **conflict** — large divergence (e.g. one band says 2 h sleep, another says 7 h) → flag prominently;
  **never silently merge.** The user picks, or NOOP keeps the higher-trust source and labels it.

Tolerances live in the same policy table (per-metric, both platforms read the same constants). This is a
threshold comparison — deterministic, explainable, no statistics beyond a clamp and a percentage. The
output rides on `ResolvedMetricPoint` as a new field; existing consumers that ignore it are unaffected.

### 3. Day ownership for scores (unchanged)
Scores (Charge/Effort/Rest) must never be computed from a mix of sources — that invariant already exists
via `DayOwnerResolver`. v5 does **not** touch it: fusion is for *displayed vitals and trends*, scoring
stays single-owner-per-day. The fused view labels which device owns the day's scores using the resolver's
existing output.

### Research grounding (cited approach, branded but transparent)
- **Best-signal selection** follows the consumer-wearables consensus that dedicated sensors beat proxies:
  wrist pedometers count steps directly while a chest/forearm strap *estimates* from motion+HR (this is why
  the WHOOP itself historically didn't surface steps). We encode that as the trust tier, not as a vendor
  preference.
- **Cross-source agreement** is a standard **Bland–Altman-style agreement** intuition (difference vs mean),
  reduced to a simple tolerance check for display — we surface the *spread*, we don't claim a true value.
- **No black box.** Like Charge/Effort/Rest, the policy and tolerances are published, inspectable
  constants — that transparency is both the honesty differentiator and the legal cover. The phrase
  "best signal" is always backed by a named, visible reason ("Steps from Mi Band — counts directly").

---

## Architecture & files (engine package + Kotlin twin + UI)

**Principle:** pure fusion logic in the shared Swift package (serves mac + iOS) + a value-for-value Kotlin
twin in `android/`, both with unit tests; UI per platform. Mirror the existing `resolvedSeries` twin
discipline exactly (it's already byte-identical across platforms).

### Shared engine — `Packages/StrandAnalytics` (Swift, serves mac+iOS)
New, pure, dependency-free files (sit alongside `DayOwnerResolver.swift`, `VitalBands.swift`, etc.):

- **`MetricArbitrationPolicy.swift`** — the data table: per-metric trust-tier mapping, per-source
  capability→tier rules, and cross-validation tolerances. Pure constants + a `tier(metric:source:)` and
  `tolerance(metric:)` lookup. **This is the heart of v5** and the only file a new device touches.
- **`FusionResolver.swift`** — pure functions that take `[SourcedDailyMetric]` (or candidate rows) for a
  day/metric and return a `FusedMetricPoint { value, winningSource, contributors:[ContributingSource],
  agreement: .agree/.minorDelta/.conflict }`. No I/O — the `Repository` feeds it rows it already reads.
- **`FusionTypes.swift`** — `FusedMetricPoint`, `ContributingSource`, `AgreementState`, a generalised
  `FusionSource` enum (extends today's `DailyMetricSource`).

`Repository.resolvedSeries` / `sourceCandidates` are **refactored to delegate to** `MetricArbitrationPolicy`
+ `FusionResolver` (keeping their public signatures and current behaviour for WHOOP/Apple). The new
"Your Data, Fused" read model (`FusedRecord`) is built in `Repository` from rows it already loads.

### Kotlin twin — `android/app/src/main/java/com/noop/analytics/`
- **`MetricArbitrationPolicy.kt`**, **`FusionResolver.kt`**, **`FusionTypes.kt`** — value-for-value ports.
- `WhoopRepository.sourceCandidates` (currently L690) is refactored to delegate to the policy, exactly as
  the Swift side does, preserving the existing `#443` Health-Connect-weight behaviour and all current tests.

### UI (per platform — not shared)
- **macOS/iOS:** a new **"Your Data, Fused"** screen (`Strand/Screens/FusedRecordView.swift`), reachable
  from Data Sources and Today. Reuses `StatePill`, the existing card chrome, `ScreenScaffold`.
- **Android:** `android/app/src/main/java/com/noop/ui/FusedRecordScreen.kt`, mirroring it; surfaced from
  `DevicesScreen` / Data Sources.
- Both surface provenance via the existing pill/caption components — we extend, not replace.

### What to reuse (explicit)
`DeviceRegistry` · `PairedDevice.capabilities` · `SourceCoordinator` (untouched) · `resolvedSeries` /
`sourceCandidates` / `appleCompatibleKey` (refactored to delegate) · `DailyMetricSource` / `vitalPriority`
/ `SourcedDailyMetric` · `DayOwnerResolver` · `RepositoryFreshness` · all importers · `StatePill` + Data
Sources cards.

### What is genuinely new
The policy table, the cross-validation/agreement pass, the `FusedRecord` read model, and the two
"Your Data, Fused" screens. Roughly: ~3 small pure Swift files + 3 Kotlin twins + 2 UI screens + tests.

---

## Cross-platform plan

Per the project's hard rule, every change reaches mac / iOS / Android:
- **mac + iOS** are covered by the shared `StrandAnalytics` Swift package automatically (both targets link
  it). UI screen is written once in SwiftUI and used by both (it already works that way for Data Sources).
- **Android** always needs the Kotlin hand-port. The fusion engine ports cleanly because it's pure (the
  `resolvedSeries`/`sourceCandidates` twin already proves this). The UI screen is a separate Compose write.
- **Parity gate:** the Swift `FusionResolverTests` and Kotlin `FusionResolverTest` run the **same fixture
  set** (same metric rows in, same fused output expected) — the established discipline for the resolver
  twin. Central build-verify all three platforms once (no per-agent gradle runs).
- **Windows port** (separate spec, 2026-06-12): the engine being pure Swift means it's portable later; out
  of scope here, but the policy table is the only thing that platform would re-read.

---

## UX (screens/flows per platform — honest + skimmable)

### "Your Data, Fused" (the new headline screen — all platforms)
A read-only, skimmable record. For each core metric, one row:

```
Resting HR      52 bpm     ● from WHOOP        (Apple Health agrees: 53)
Steps        8,420         ● from Mi Band      (counts directly · strap estimate hidden)
Sleep         7h 12m       ● from WHOOP        ⚠ Apple Health says 6h 40m — tap to compare
Skin temp     34.1 °C      ● from WHOOP
HRV             68 ms      ● from WHOOP        (no second source)
```

- Each row shows the **winning value**, a **provenance pill** naming the source, and a **one-line reason**
  when "best signal" needs justifying ("counts directly", "best stager").
- **Agreement inline:** `agree` → quiet parenthetical; `minorDelta` → both values, neutral; `conflict` →
  ⚠ chip + "tap to compare" opening a small sheet showing every source's value side by side and which one
  NOOP is using and *why* (its trust tier). User can **pin a preferred source per metric** (stored as a
  lightweight override; the resolver already has a per-day lock concept via `DayOwnerResolver` to model on).
- **Day badge:** "Today's record owned by WHOOP" via `DayOwnerResolver` — so scores' single-owner is
  honest.

### Devices screen (existing — light additions)
Each paired `PairedDevice` already lists brand/model/status. Add a **"Provides:"** capability line
("Provides: HR · HRV · Sleep · Skin temp") from `PairedDevice.capabilities`, and a tiny "owns N days"
coverage count from generalised `RepositoryFreshness`. No flow change.

### Data Sources screen (existing — light additions)
The "Freshness Pipeline" card generalises from 3 fixed rows (imported/computed/Apple) to **one row per
active source** with its day count. Add an entry point to "Your Data, Fused".

### Honest empty/single-source states
- **Single WHOOP, nothing else:** the fused view degrades to a plain record with no provenance noise — it
  must not *manufacture* a multi-source experience. Pills only appear when >1 source contributes. (This
  matches `vitalRows` already falling back to `.localCache` when there's nothing to resolve.)
- **No conflict invented:** if only one source has a metric, no agreement chip shows.

### Copy rules (shipped strings)
- USD only if cost is mentioned anywhere ("free vs $300–480/yr").
- **Never** name any AI/LLM in shipped copy (the only legitimate mention is the opt-in bring-your-own-key
  AI Coach, which is unrelated to this pillar).
- Wellness framing throughout (next section). "Best signal", "your record", "agrees/differs" — never
  "accurate", "correct", "diagnose".

---

## Non-clinical / legal framing (wellness-only, NOT medical)

This pillar is **higher legal risk than most** because "one health record" + "cross-validation" can *sound*
diagnostic. Hard guardrails on shipped copy and behaviour:

- **Wellness, not medical.** NOOP is a wellness and self-knowledge tool. It does **not** diagnose, treat,
  cure, or monitor any condition. Aligns with the existing `DISCLAIMER.md` / `TERMS.md` posture.
- **"Best signal" ≠ "accurate" / "correct" / "clinical".** We say a source is *higher-trust for this
  metric* with a plain reason; we never assert a measurement is true or medically valid.
- **Conflicts are shown, not adjudicated as clinical fact.** "Your two bands report different sleep totals"
  is a transparency statement, not a diagnosis that either is wrong. We never tell the user a reading is
  "abnormal" or implies a health problem.
- **No alerts on values.** The fused view never flags a number as concerning, out-of-range-medically, or
  actionable for a condition. (It may note device disagreement; it must not note physiological alarm.)
- **No new sensitive data category.** Fusion only re-presents data the user already imported locally; it
  introduces no new collection. Nothing leaves the device — reinforce this on the screen ("Everything
  stays on this device", matching the Data Sources subtitle).
- **Provenance protects the user and us.** Always naming the source means we never launder one vendor's
  reading as NOOP's clinical claim.
- A short on-screen note: *"NOOP picks the best-sourced number and shows you where each came from. It's for
  wellness and curiosity — it doesn't diagnose or replace medical advice."*

---

## Test plan

Mirror the existing `resolvedSeries`/`sourceCandidates` twin-test discipline (Swift + Kotlin, shared
fixtures).

**Pure engine (Swift `StrandAnalyticsTests` + Kotlin parity):**
1. **Trust ordering** — for each core metric, given candidate rows from multiple sources, the winner is the
   highest-trust tier; ties broken stably. Steps-from-band beats strap-estimate; sleep-from-WHOOP beats
   phone buckets.
2. **Cross-validation classification** — agree / minorDelta / conflict at the exact tolerance boundaries
   (±1 from each edge), per metric.
3. **Conflict never silently merges** — a large divergence yields `conflict` with both contributors
   retained, winner = higher trust, no averaging.
4. **Single-source degradation** — one source ⇒ no agreement state, no pills, value passes through.
5. **Provenance integrity** — `winningSource` always matches the source that supplied the value.
6. **Regression lock** — `sourceCandidates` after refactor returns **byte-identical** output to today for
   the WHOOP-preferred and Apple-preferred cases (snapshot the current outputs first, assert unchanged) —
   protects `#196`, `#443`, and `appleCompatibleKey`.
7. **Swift↔Kotlin parity** — identical fixtures, identical fused output (the established gate).

**Integration (Repository / WhoopRepository):** `FusedRecord` built from seeded multi-source rows resolves
correctly end-to-end; `DayOwnerResolver` still single-owns scored days.

**No UI snapshot tests on mac (headless XCTest can't run UI)** — verify the screen via the SwiftUI preview +
Android JVM mirror per `reference_noop_build_test_env.md`.

---

## Phasing (MVP vs later)

**MVP (this spec):**
1. `MetricArbitrationPolicy` + `FusionResolver` + `FusionTypes` (Swift) and Kotlin twins, with tests.
2. Refactor `resolvedSeries`/`sourceCandidates` to delegate (regression-locked).
3. Cross-validation/agreement pass on resolved points.
4. **"Your Data, Fused"** read-only screen (mac/iOS + Android), pills + inline agreement + conflict sheet.
5. Generalise `RepositoryFreshness` and the Devices/Data Sources additions (capabilities line, per-source
   coverage).
6. Sources covered at MVP = the ones that already import: **WHOOP · NOOP-computed · Apple Health · Health
   Connect · Mi Band/Xiaomi** (+ nutrition/lifting as single-source passthroughs).

**Later:**
- **User per-metric source pinning** persisted (lightweight override table; model on the existing day-lock).
- **Polar / Garmin / Oura** as first-class fusion sources — each is *just a policy + capability
  registration* once its importer/live source lands (the whole point of the table-driven design).
- **Per-day timeline** of which band owned each day (history view).
- **Concurrent live multi-source** (two radios at once) — explicitly out of scope; needs `SourceCoordinator`
  rework and battery/UX study (see Open questions).
- **Confidence surfacing** tie-in with the existing `ScoreConfidence` work.

---

## Open questions

1. **Live vs stored fusion.** MVP fuses the *stored daily record*; live streaming stays single-active-source
   via `SourceCoordinator`. Do we ever want concurrent live multi-radio (e.g. WHOOP recovery + Polar
   workout HR simultaneously)? That's a real `SourceCoordinator` rework + battery cost — defer, or scope it?
2. **Per-metric pinning UX.** Should a user override ("always trust my Garmin for steps") be per-metric,
   per-source-pair, or per-day? `DayOwnerResolver` gives a per-day lock to model on — is metric-level worth
   the extra surface in MVP, or strictly "later"?
3. **Conflict tolerances** — start with hand-set per-metric thresholds (RHR ±3, sleep ±20 min, steps ±10%).
   Are these the right defaults, and do we expose them or keep them fixed constants?
4. **Skin-temp redundancy** — when two sources both report skin temp, do we prefer finer scale, or the
   day-owner device, or show both? (Edge case; few users have two temp sources today.)
5. **Naming.** "Your Data, Fused" vs "Your Record" vs "Sources, Combined". Avoid anything that sounds
   clinical ("Unified Vitals" reads medical — avoid).
6. **Should the fused value ever differ from the day-owner's value?** Fusion (best-per-metric) can pick a
   metric from a non-owner device while scores use the day-owner. Is that confusing, and how do we caption
   the distinction so it stays honest rather than contradictory?
