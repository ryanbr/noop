# NOOP v5 — Health Records ("Lab Book") Design Spec

**Pillar:** Health Records (labs-equivalent) — NOOP's privacy-first answer to WHOOP "Advanced Labs."
**Status:** Design only. No code in this document.
**Date:** 2026-06-19
**Platforms:** macOS + iOS (shared Swift engine) and Android (Kotlin twin). UI per platform.

> **One-line thesis:** You already get bloods, blood pressure, scans and body measurements from your own doctor or pharmacy. NOOP gives you a private place to *keep* those numbers and *see them next to your wearable signals* — entirely on your device. We never test you, never read a result for you, and never tell you what it means medically.

---

## Naming decision

**Chosen name: "Lab Book"** (feature surface), with the umbrella section title **"Records"** in navigation and the data type called a **Marker**.

Justification, having weighed the candidates:

| Candidate | Verdict |
|---|---|
| "Advanced Labs" | **Rejected.** It is WHOOP's product name. Reusing it invites a trademark conflict and, worse, implies NOOP *performs* lab testing (it does not — that would be a clinical/diagnostic claim). |
| "Markers" / "My Markers" | Good ("marker" is the honest noun for a stored value), but as a *screen title* it's abstract and cold. Kept as the **data-type noun** instead. |
| "Records & Results" | Accurate but long; "Results" leans diagnostic. |
| "Health Records" | Clear, but collides with Apple's own "Health Records" (their FHIR clinical-records feature) — confusing when we *import from* exactly that. |
| **"Lab Book"** | **Chosen.** Evokes a personal logbook you keep yourself — a *notebook*, not a laboratory. It frames NOOP as the place you *write down and look back at* your own numbers, which is exactly the legal posture: a user-owned ledger, not a testing service or interpreter. Pairs naturally with the existing "journal" idiom already in the app. |

Copy rule everywhere: **"Lab Book"** for the place, **"marker"** for one stored value (e.g. "Add a marker", "12 markers tracked"), **"reading"** for one dated entry of a marker. Never "test", "result analysis", "panel interpretation", or "diagnosis" in shipped copy.

---

## Goal & differentiation (why only NOOP)

**Goal.** Let a user keep their *own existing* health numbers — blood-pressure readings, blood-panel values (cholesterol, glucose/HbA1c, ferritin, vitamin D, …), body measurements, scan/imaging *values*, and free-text appointment notes — in a typed, local store, and **correlate** them against the wearable biometrics NOOP already computes (resting HR, HRV, sleep, Charge, Effort, skin-temp deviation, steps, weight). Records also enrich the opt-in BYO-key AI Coach and a new **Health → Lab Book** surface.

**Why only NOOP can offer this honestly:**

1. **It's the inverse of "Advanced Labs."** WHOOP/Function/Superpower *sell you blood tests* and store the results *in their cloud*, behind a subscription, where the company reads them. NOOP's pitch is the opposite and is structurally impossible for them to copy without dismantling their model: **you bring numbers you already own, and they never leave the device.** There is no test to buy, no lab partner, no server.
2. **Local correlation against raw-signal-derived metrics.** NOOP already turns raw PPG/R-R/accelerometer/skin-temp into daily series (`metricSeries`) and already runs an on-device Pearson + lagged correlation engine (`CorrelationEngine`, surfaced in `CompareView`/`InsightsScreen`). A marker is just another `(day, value)` series — so the moment a user logs three cholesterol readings, NOOP can line them up against the *same window* of resting HR, HRV or sleep with **zero new math** and **zero network**. Oura/Apple/Garmin can show you imported lab values but do not fuse them with their own wearable signal on-device in a correlation surface; the cloud-labs players can't, because the wearable side isn't theirs.
3. **Privacy is the product, not a setting.** "Your bloods never touch a server" is a claim only a local-first app can make truthfully. This is the headline.

**What it is NOT (load-bearing):** not a test, not a diagnosis, not medical advice, not a clinician-reviewed record, not HIPAA-covered. See **Non-clinical / legal framing**.

---

## Data & signals used (already available vs new)

### Already available (reuse, do not rebuild)
- **`metricSeries` table** (`WhoopStore` v9 / Android `MetricSeriesRow`): the generic EAV `(deviceId, day, key, value: REAL)` store. **A daily marker series is written here verbatim** under a dedicated source id, exactly like nutrition (`nutrition-csv`) and mood (`noop-mood`) already do. No schema change needed for the *daily-aligned* read path that Compare/Insights/Coach use.
- **`CorrelationEngine`** (`StrandAnalytics`): `pearson`, `alignByDay`, `lagged`, `pValue`. Markers feed straight in.
- **`Repository.resolvedSeries` / `exploreSeries`** and the **per-source precedence resolver**: markers are single-source by design (like nutrition/mood) so they resolve to *themselves only* — the existing `sourceCandidates` "any other source → itself only" branch already covers them.
- **`MetricCatalog`** (`Strand/Data/MetricCatalog.swift`): the catalog that drives Compare's metric picker and Explore. Markers appear as catalog descriptors so they're selectable on those existing screens with no per-screen wiring.
- **`StrandImport` framework**: `ImportCoordinator`, `CSVParsing`, `ZipPeek`, `ImportSummary`, the `AppleHealthImporter` XML path. The CSV marker importer reuses `CSVParsing`; the Apple clinical-records path reuses the security-scoped picker + summary idioms.
- **`DataSourcesView` import-card pattern** (Swift) / `DataSourcesScreen.kt` (Kotlin): the exact "parse file → upsert metricSeries → `repo.refresh()`" lightweight flow that nutrition + lifting already use. The Lab Book CSV/Apple imports clone it.
- **AI Coach `buildContext()`** (`Strand/AI/AICoach.swift`): the compact text brief sent (only with explicit consent, BYO-key) to the user's chosen provider. We append a short, opt-in markers block.

### New (this pillar adds)
- A **`labMarker` record table** (the *source of truth* for a marker reading — richer than the daily `metricSeries` projection): one row per reading with `value`, `unit`, `takenAt` (instant, not just a day), `category`, `markerKey`, `source`, free-text `note`, and `valueText` (for non-numeric / qualitative results). This is needed because a single day can hold multiple readings, readings carry a precise timestamp and unit, and notes/qualitative results don't fit a `REAL`-only `metricSeries` cell.
- A **derived daily projection**: for each numeric marker, the latest (or mean) reading per day is upserted into `metricSeries` under the `lab-book` source so it lights up Compare/Explore/correlation/Coach unchanged. The `labMarker` table is the book; the `metricSeries` projection is how the book talks to the rest of the app.
- A **marker dictionary** (`MarkerCatalog`): ~30 common, *non-diagnostic* marker definitions (key, display name, category, canonical unit, optional informational reference-range *text from the user's own report*, decimals, higher-is-better hint = nil for most). Extensible: the user can add a **custom marker** (free name + unit) so the store is never gated by our dictionary.
- New **import surfaces**: manual entry (MVP), CSV (phase 2), Apple Health clinical records / FHIR on iOS (phase 3), PDF/photo OCR (phase 4, later).

---

## On-device algorithm (grounded; cite the approach)

There is **no new statistics** — and that is deliberate. The pillar's correctness comes from honest data plumbing, not a new model.

1. **Day-alignment + Pearson.** A numeric marker series `[(day, value)]` is correlated with any wearable series using the existing `CorrelationEngine.alignByDay` (inner-join on `yyyy-MM-dd`) + `CorrelationEngine.pearson` (product-moment `r`, OLS slope/intercept, and an approximate two-sided p-value via the t→normal approximation already documented in that file). This is the standard Pearson correlation; we reuse it byte-for-byte.

2. **Sparse-marker handling (the real design problem).** Bloods are taken every few *months*, not daily. Naive day-alignment would yield 3–6 overlapping points — below the engine's `n >= 3` floor and statistically near-meaningless. So Lab Book correlation uses a **windowed-aggregate** approach grounded in how clinicians already read trends:
   - For each marker reading on day *D*, pair it not with the wearable value *on D alone* but with the **mean of the wearable series over a configurable window around D** (default: the **14 days up to and including D** — "what your body was doing in the fortnight before the draw"). This is a deliberate, disclosed modelling choice, not a hidden one.
   - Window width is shown in the UI and adjustable (7 / 14 / 30 days).
   - This mirrors the established epidemiological practice of relating a point-in-time lab value to a *trailing exposure window* of a continuously-measured covariate; it is the same idea as a moving-average feature, kept fully deterministic and on-device.
   - The result is reported with **brutal honesty about n**: NOOP shows the *exact* number of marker readings used and never renders a correlation conclusion sentence below a floor (default **n ≥ 4 readings**; below that it shows the points but says "not enough readings to read a trend yet").

3. **No causal language, ever.** The output copy is the same restrained idiom already shipped in `CompareView.insightSentence`: "when X is higher, Y *tends to* be …", strength words (negligible/weak/moderate/strong), and an explicit "this shows association, not cause" line. We add one mandatory clause for markers: *"This is your own data sitting side by side — it is not a medical finding."*

4. **Trend (single marker, no wearable).** Even with one marker and no pairing, NOOP shows the reading-over-time sparkline + a plain slope ("your last 3 LDL readings: 3.4 → 3.1 → 2.9 mmol/L, trending down"). This is descriptive arithmetic on the user's own entries, not interpretation.

**Explicitly out of scope of the algorithm:** reference-range *judgement* ("high"/"low"/"abnormal"), risk scores, any threshold NOOP itself defines. If a report's own range is captured as text, we may show it *verbatim as the user entered it* with a "from your report" label — NOOP never computes or asserts normality.

---

## Architecture & files (engine package + Kotlin twin + UI; what to reuse)

### Shared Swift engine — `Packages/StrandAnalytics` (+ store in `WhoopStore`, model/import in `StrandImport`)

Pure, DB-free, deterministic logic goes in `StrandAnalytics`; persistence in `WhoopStore`; parsing in `StrandImport`. This keeps the engine unit-testable with no database, exactly like `CorrelationEngine` and `NutritionCsvImport` today.

| New/changed file | Package | Responsibility |
|---|---|---|
| `LabMarker.swift` (new) | `StrandImport` | `LabMarker` value type: `markerKey`, `category`, `value: Double?`, `valueText: String?`, `unit: String`, `takenAt: Date`, `source: String`, `note: String?`, `referenceText: String?`. Plus `LabMarkerCategory` enum (bloodPanel, bloodPressure, bodyMeasurement, imaging, appointmentNote, other). Mirrors the existing `ImportModels` style. |
| `MarkerCatalog.swift` (new) | `StrandImport` | The non-diagnostic marker dictionary (key → name/category/canonical unit/decimals/`referenceTextHint`). Pure data. |
| `LabBookProjection.swift` (new) | `StrandAnalytics` | Pure: fold `[LabMarker]` → daily `[(day, key, value)]` per marker (latest-or-mean-per-day rule), and the **windowed-aggregate pairing** (`pairMarkerToWearable(marker:wearable:windowDays:)`) used before `CorrelationEngine.pearson`. No DB, no I/O — fully testable. |
| `LabMarkerStore.swift` (new) | `WhoopStore` | GRDB CRUD on a new `labMarker` table (migration **v17**), exactly mirroring `MetricSeriesStore`'s actor/`syncWrite`/`syncRead` idiom: `upsertLabMarkers`, `labMarkers(category:)`, `labMarkers(markerKey:)`, `markerKeysPresent()`, `deleteLabMarker(id:)`. On every write it **also upserts the daily projection into `metricSeries`** under source `lab-book` so Compare/Explore/Coach see it. |
| `LabMarkerCsvImport.swift` (new) | `StrandImport` | Phase 2. Parse a generic markers CSV (date, marker name, value, unit, note) via the existing `CSVParsing`. Returns `[LabMarker]` + an `ImportSummary`. Tolerant column mapping like the nutrition importer. |
| `AppleClinicalRecordsImporter.swift` (new) | `StrandImport` (iOS-guarded) | Phase 3. Reads Apple Health **clinical records (FHIR)** via HealthKit's `HKClinicalType` (`labResultRecord`, `vitalSignRecord`, etc.), maps FHIR Observation resources → `LabMarker`. iOS-only behind `#if os(iOS)`; harmless absent on Mac/Android. |
| `CorrelationEngine.swift` (reuse, **no change**) | `StrandAnalytics` | Already provides `pearson`/`alignByDay`/`lagged`/`pValue`. |
| `MetricSeriesStore.swift` (reuse) | `WhoopStore` | The projection sink. |
| `MetricCatalog.swift` (extend) | `Strand` (app) | Add a `"Lab Book"` category + descriptors built from `MarkerCatalog` so markers appear in Compare's picker and Explore. |
| `Repository.swift` (extend) | `Strand` (app) | Add `labMarkers(...)` read passthroughs and ensure `sourceCandidates` treats `lab-book` as single-source (it already falls through to "itself only"). |

### UI (per platform, not shared)
- **macOS + iOS:** new `LabBookView.swift` (the book: add/edit markers, per-marker history, sparkline, "correlate against a signal" picker that reuses the Compare correlation card). A `MarkerEditorView` sheet for manual entry. New cards in `DataSourcesView` for CSV + (iOS) Apple clinical records. A **Lab Book entry point on `HealthView`**.
- The marker↔signal correlation UI **reuses `CompareView`'s `pairCard` / insight language** so there is one correlation idiom across the app.

### Android twin — `android/`
| New/changed file | Responsibility |
|---|---|
| `data/Entities.kt` (extend) | Add `LabMarkerRow` `@Entity` (table `labMarker`) mirroring the Swift row, + Room migration matching **v17**. `MetricSeriesRow` already exists for the projection. |
| `data/WhoopDao.kt` (extend) | Lab-marker CRUD + the `metricSeries` projection upsert. |
| `analytics/LabBookProjection.kt` (new) | Value-for-value twin of the Swift projection + windowed-pairing logic. |
| `ingest/LabMarkerCsvImporter.kt` (new) | Twin of the Swift CSV importer (phase 2). |
| `ingest/HealthConnectImporter.kt` (extend) | Phase 3 Android equivalent: Health Connect has **no clinical/FHIR records type**, so on Android the "clinical records" import is **CSV + manual only** (documented honestly; Health Connect covers vitals like blood pressure where the user has them, which we map to markers). |
| `ui/LabBookScreen.kt`, `ui/MarkerEditorSheet.kt` (new) | Compose UI; correlation surface reuses `InsightsScreen`/`CompareScreen` Pearson helpers (`pearsonAligned`, lines ~1522). |
| `ui/DataSourcesScreen.kt`, `ui/HealthScreen.kt` (extend) | Add the Lab Book entry + import cards. |

**Reuse summary:** `metricSeries`, `CorrelationEngine`, `Repository.resolvedSeries`/`exploreSeries`, `MetricCatalog`, `CSVParsing`, `DataSourcesView`/`Screen` card pattern, AICoach `buildContext`, and the `nutrition-csv`/`noop-mood` single-source precedent. New code is one table + one projection + a marker dictionary + per-platform UI.

---

## Cross-platform plan

- **Pure logic parity first.** `LabBookProjection` (Swift) and `LabBookProjection.kt` ship together with **identical fixtures** — the same `[LabMarker]` input must produce byte-identical daily projections and windowed pairs on both. This is the project's standard footgun (Kotlin/Swift parity); test it centrally.
- **DB migration lockstep.** Swift `WhoopStore` **v17** ↔ Android Room migration land in the same release; both additive (new `labMarker` table, no existing-row touch) so an old reader is unaffected — matches the additive-migration discipline already used through v16.
- **Single source id `lab-book`.** The projection device-id is constant across platforms so a future cross-device file sync (out of scope here) would line up. Per the memory rule, markers being single-source means the resolver needs no new precedence branch.
- **iOS-only clinical records.** The FHIR/`HKClinicalType` path is `#if os(iOS)` and *absent* on Mac/Android. The cross-platform floor is **manual + CSV** (works on all three); Apple clinical import is an iOS bonus, Health Connect vitals a partial Android bonus. Documented honestly so no platform looks broken.
- **No gradle in implement waves** (per workflow rule): build-verify all three platforms centrally once; the Swift package test suite + Android JVM mirror cover the engine.

---

## UX (screens/flows per platform — honest + skimmable)

### Entry points
- **Health → Lab Book** card ("Your bloods, BP and body numbers — kept private, on \(device)").
- **Data Sources** gains: *Add a marker* (manual), *Markers CSV*, and on iOS *Apple Health Records (clinical)*.

### Lab Book (main screen) — all platforms
- Header: count + scope line: **"12 markers · all stays on this \(device). Nothing is sent anywhere."**
- Grouped by category (Blood panel / Blood pressure / Body / Imaging / Notes / Custom).
- Each marker row: name, latest reading + unit, a tiny sparkline, last-taken date.
- Tap a marker → **Marker detail**: full reading history (table + line chart), trend sentence ("3 readings, trending down"), the user's own captured reference text shown verbatim with a *"from your report"* tag, and a **"Compare with a signal"** button.
- **Compare with a signal** → opens the (reused) correlation card: pick a wearable metric (resting HR, HRV, sleep, Charge, weight…), choose window (7/14/30d), see `r`, n readings used, and the restrained insight sentence + the mandatory *"side-by-side, not a medical finding"* line. Below the floor (n<4) it shows the dots but withholds the conclusion sentence.

### Add / edit a marker (manual entry — MVP)
- Sheet: pick from `MarkerCatalog` (searchable) **or** "Add custom marker" (name + unit). Then: value (numeric, with the marker's canonical unit prefilled and a unit switcher where sensible, e.g. mmol/L ↔ mg/dL for glucose/cholesterol — conversion shown transparently), date/time taken, optional note, optional "reference range from my report" free-text.
- Blood pressure is a **paired marker** (systolic/diastolic entered together, stored as two marker keys) so it reads naturally.
- Save → write `labMarker` row(s) → project to `metricSeries` → `repo.refresh()` → toast.

### Import flows
- **CSV** (phase 2): same card idiom as nutrition — choose file, tolerant parse, summary line ("Imported 18 readings across 6 markers · 2024-01 – 2026-05 · 2 rows skipped").
- **Apple Health clinical records** (phase 3, iOS): a permission card explaining NOOP will read the clinical records *Apple already holds on the device* (no network), then a one-tap pull. Honest copy: "Only records your providers sent to Apple Health appear here; not every clinic participates."

### Empty states (honest)
- No markers: "Keep your own numbers here — type in a blood-pressure reading or a cholesterol value from your last appointment. It stays on this \(device), and over time you'll see how it lines up with your sleep, heart rate and recovery."
- No wearable overlap yet: "Log a few more readings (and keep wearing your strap) and NOOP can line this marker up against your signals."

---

## Non-clinical / legal framing (wellness-only; never diagnostic)

This pillar carries the **highest legal sensitivity** in the app because it touches lab values and BP. The framing is non-negotiable and appears in-product, not just in docs. It is consistent with the shipped `DISCLAIMER.md`, `TERMS.md`, and the existing in-app non-clinical lines (Mind, Vitality, HRV snapshot, Trends report).

**The exact in-product disclaimer (shown on first use of Lab Book, and linked from the screen header):**

> **Lab Book is a private notebook, not a medical service.**
> - NOOP **stores and lines up the numbers you enter yourself**. It does **not** test you, **read** your results, give medical advice, or **diagnose** anything.
> - Anything you see here — including any side-by-side trend — is **your own information shown back to you**. It is an **association**, never a cause, and never a medical finding.
> - We never decide whether a value is "normal," "high," or "low." Any reference range shown is **exactly what you typed from your own report**.
> - Your records **never leave this \(device)**. There is no account, no cloud, no NOOP server. Because NOOP is an independent app you run yourself — **not a healthcare provider** — it is **not "HIPAA-covered"**, and that protection does not apply here; the safety comes from the data being **local-only and yours**.
> - **Always rely on your doctor, pharmacist, or a qualified professional** to interpret results and make decisions. If a number worries you, talk to them — not to an app.

**Hard rules for implementers (mirrors existing memory/UI rules):**
1. No word in shipped copy that asserts a clinical judgement: never "abnormal", "diagnose", "you have", "risk of", "deficiency", "out of range" *as NOOP's own statement*.
2. Correlation copy uses the shipped restrained idiom (*tends to*, association-not-cause) + the mandatory markers clause.
3. The AI Coach markers block is **opt-in twice**: the existing global "let the coach use my data" consent **and** a separate "include my Lab Book" toggle (bloods are more sensitive than a recovery score). When included, the system prompt instruction is extended with: *"These are user-entered health numbers. You may describe trends in plain language and suggest questions to ask their doctor. Do NOT diagnose, name conditions, state whether a value is normal/abnormal, or give medical advice. Always defer to a qualified professional."*
4. Anonymity rule unchanged: no AI/LLM is mentioned anywhere except the BYO-key Coach. The Coach already provides its own key; nothing here changes that.
5. Currency in any copy is **USD**; the privacy contrast line ("no subscription, no cloud labs") uses USD if a price is ever quoted.
6. The Trends/share PDF already flags measured-vs-computed; if markers ever appear in an export they carry a **"self-entered, not verified"** tag so a doctor never mistakes them for lab-verified values.

---

## Test plan

**Pure-logic unit tests (Swift `StrandAnalyticsTests` + Android JVM mirror — identical fixtures):**
- `LabBookProjection`: latest-per-day and mean-per-day folding; multiple readings same day; numeric vs `valueText` handling; BP pair split into two keys.
- Windowed pairing: a marker on day D pairs with the correct trailing-window mean; window 7/14/30; days with no wearable coverage are dropped; the n-floor is respected.
- Correlation: feed projected pairs through `CorrelationEngine.pearson` and assert `r`/n/p match a hand-computed fixture (reuse existing Pearson test scaffolding).
- Unit conversion (mmol/L↔mg/dL etc.): exact, reversible, fixture-checked.
- **Parity test:** the same `[LabMarker]` JSON fixture produces byte-identical projection + pairs in Swift and Kotlin.

**Store tests (`WhoopStoreTests` + Room):**
- v17 migration is additive and idempotent; old rows untouched.
- `upsertLabMarkers` is idempotent by natural key; the `metricSeries` projection appears under `lab-book` after a write; delete removes both the marker row and its projected day.

**Import tests (`StrandImportTests`):**
- CSV: tolerant column mapping, skipped-row counting, summary date span.
- Apple clinical (iOS): a fixture FHIR Observation maps to the right `LabMarker` (run on an iOS test target; the headless macOS XCTest limitation is known — verify via the package test + a fixture, not a live HealthKit pull).

**UI smoke (manual, per platform):** add a marker → appears in Lab Book and in Compare's picker → correlation card renders with the honest copy and n-floor behaviour → AI Coach block only appears with both consents on.

---

## Phasing (MVP vs later)

**Phase 1 — MVP (manual + the whole engine).**
- `labMarker` table (v17) + `LabMarkerStore` + `metricSeries` projection.
- `MarkerCatalog` (~30 common markers) + custom markers.
- `LabBookProjection` + windowed pairing (Swift + Kotlin parity).
- Manual entry UI (incl. paired BP) on all three platforms; Lab Book screen + marker detail + "Compare with a signal" (reusing the Compare correlation card).
- Catalog extension so markers appear in Compare/Explore.
- Full non-clinical disclaimer + Coach opt-in (second toggle) + markers context block.

**Phase 2 — CSV import.** Generic markers CSV via `CSVParsing`; Data Sources card on all platforms.

**Phase 3 — Apple Health clinical records (FHIR), iOS only.** `HKClinicalType` → `LabMarker`. Android: map Health Connect vitals (e.g. blood pressure) where present; document that FHIR clinical import is iOS-only.

**Phase 4 — PDF / photo OCR (later, opt-in, on-device).** Let a user point at a lab-report PDF or a photo and *suggest* markers to confirm. Strictly on-device OCR (Vision on Apple / ML Kit on Android), **user confirms every extracted value** before it's saved (never silent), and the disclaimer is reinforced ("we read characters off your file; we do not interpret the report"). No cloud OCR, ever — that would break the privacy contract.

---

## Open questions

1. **Window default + label.** Is a 14-day trailing window the right default for sparse bloods, and do we let the user also pick "value on the exact day" (n will be tiny)? Leaning 14d default with 7/30 options and a clear "trailing N days before the reading" caption.
2. **Reference ranges.** Confirm we only ever show the *user-entered* range verbatim and never ship our own range tables (even "informational"). Current spec says yes — never ship ranges. Worth a final sign-off given the legal weight.
3. **Blood pressure modelling.** Two marker keys (systolic/diastolic) entered as a pair vs a single composite — spec picks two keys for clean correlation; confirm UI reads naturally.
4. **Unit policy.** Which markers get a unit switcher (mmol/L↔mg/dL is clear for lipids/glucose; most others have one canonical unit)? Need the small switcher list.
5. **Coach exposure of bloods.** Is a *second* explicit consent enough, or should Lab Book values be summarised more coarsely (e.g. "LDL trending down" rather than exact values) when sent to a third-party provider? Leaning: send trend + latest value only, never the full history, and only with the second toggle on.
6. **OCR scope (phase 4).** Vision/ML Kit confidence threshold + the confirm-every-value flow — defer detailed design until phases 1–3 ship.
7. **Marker dictionary breadth.** ~30 markers for MVP — which 30? Draft list (lipids, glucose/HbA1c, ferritin/iron, vitamin D, B12, TSH, CRP, eGFR/creatinine, ALT/AST, BP systolic/diastolic, resting weight/body-fat/waist) — needs a final cut so we don't imply clinical completeness.
