# NOOP scoring — "Charge / Effort / Rest" design

**Goal:** Give NOOP its own first-class daily scores — **Charge** (recovery), **Effort** (strain),
**Rest** (sleep) — all out of 100, computed across WHOOP 4.0 and 5.0/MG, competitive with WHOOP's
Recovery/Strain/Sleep while staying transparent and honest.

**Approved:** 2026-06-12 (the maintainer). Names = Charge/Effort/Rest. Scope = rebrand + rescale + enrich.

## Principles

- **Internal data keys are unchanged** (`recovery`, `strain`, `sleep_performance`) so years of stored
  history, imports, and the metric-series substrate keep working. Only **display names** and **Effort's
  scale** change.
- **Transparent published science stays** (Task Force 1996 HRV, Karvonen %HRR, Edwards/Banister TRIMP) —
  it's the honesty differentiator and the legal cover. We brand it, we don't black-box it.
- **Device-aware + honest about certainty.** A `confidence` tier (Solid / Building / Calibrating) rides
  each score so a sparse 5/MG day reads truthfully instead of faking a number.

## The three scores

### Charge (0–100) — replaces Recovery
Keep the HRV-dominant, baseline-normalized logistic core; re-weight to fold in skin temperature:

| Driver | Weight | Direction |
|---|---|---|
| HRV vs baseline | 0.55 | higher → more Charge |
| Resting HR vs baseline | 0.20 | lower → more |
| Rest quality (sleep) | 0.15 | higher → more |
| Respiration vs baseline | 0.05 | lower → more |
| **Skin-temp deviation** | **0.05** | **further from baseline → less** (illness/overreach) |

- SpO₂ folds in **only when real** (imported) as a small penalty below ~95%; never fabricated, never on a
  bare 5/MG.
- Cold-start → `nil` + "Calibrating — N of seed nights" (unchanged).
- New weight constant `wSkinTemp = 0.05`; HRV drops 0.60 → 0.55 to make room. Skin-temp term uses the
  absolute deviation already computed as `DailyMetric.skinTempDevC` (a z-like ±°C), entered as a
  symmetric penalty `−|dev|/scale`.

### Effort (0–100) — replaces Strain (was 0–21)
**Rescale only:** `StrainScorer.maxStrain 21.0 → 100.0`. The denominator `D = 7201` is unchanged, so the
log curve and its saturation point (TRIMP 7200 ≈ max) are preserved — a max Effort day stays as rare as a
21.0 Strain day. Enrichment:
- **Steps/active-energy floor:** when cardio TRIMP is low but step/active-kcal load is high (a long walk),
  raise Effort to a movement-derived floor so non-cardio activity still registers.
- **5/MG continuity:** Effort already reads `COALESCE(measured HR, ppg_hr)` via hrBuckets, so 5-series
  users get Effort from live + PPG HR today.

### Rest (0–100) — replaces Sleep Performance
Composite, replacing the bare efficiency proxy:

| Component | Weight |
|---|---|
| Duration vs personal need | 0.50 |
| Efficiency (asleep / in-bed) | 0.20 |
| Restorative share (deep + REM) / asleep | 0.20 |
| Consistency (sleep/wake regularity) | 0.10 |

- Personal sleep need: 8 h default, refined by recent average; hours-vs-need clamps at 100.
- Consumes whatever stages each device provides (v25 motion on 4.0; PPG/IMU on 5 as it unlocks).
- The `sleep_performance` key now stores this composite (0–100). The Charge "Rest quality" term reads it
  (÷100) instead of raw efficiency.

## Confidence tier

`ScoreConfidence { solid, building, calibrating }` derived per score:
- **Calibrating** — baseline not yet usable (Charge) or no in-bed data (Rest) or no HR window (Effort).
- **Building** — usable but thin (e.g. < ~7 nights of baseline, or a 5/MG day backed mostly by PPG-derived
  HR).
- **Solid** — full inputs present.

Surfaced as a small label/dot under each score; the metric stays nil-honest where it can't compute.

## Imported-strain wrinkle

Imported WHOOP "Day Strain" is on WHOOP's 0–21 scale. To keep the Effort axis consistent, **rescale at
import**: `WhoopExportImporter` multiplies an imported Day Strain by `100/21` when writing the `strain`
metric series, so everything stored under `strain` is 0–100. (Documented in the importer; one-line map.)

## Surfaces to update

- **Swift:** `RecoveryScorer` (skin-temp term + Rest input), `StrainScorer` (maxStrain), new
  `RestScorer`/composite in `AnalyticsEngine`, `ScoreConfidence`, `MetricCatalog` display labels +
  categories, `TodayView` (Charge ring, Effort card "of 100", Rest), Trends/Compare labels,
  `WhoopExportImporter` strain rescale.
- **Kotlin:** mirror all of the above (`RecoveryScorer.kt`/`AnalyticsEngine.kt`/`MetricCatalog.kt`/
  `TodayScreen.kt`/importer).
- **Docs/wiki:** Features, How-NOOP-Works, FAQ, the Science page, disclaimers — rename + explain the
  energy-economy framing; keep the "approximations, not WHOOP's scores" disclaimer.

## Out of scope (v1)

- No 4th blended "NOOP Score".
- No change to the sleep-staging algorithm itself (Rest consumes existing stages).
- Internal metric keys unchanged.

## Testing

- `StrainScorer`: a fixed TRIMP now maps to the 0–100 curve (update golden values ×100/21).
- `RecoveryScorer`: skin-temp term moves Charge the expected direction; absent skin-temp leaves the score
  identical to before (renormalized weights).
- New Rest composite: golden cases for duration-dominated, efficiency, restorative, consistency.
- Confidence tiers: calibrating/building/solid boundary cases.
- Import rescale: a WHOOP 0–21 Day Strain lands as 0–100.
- Cross-platform parity tests stay green (Swift ↔ Kotlin same outputs).
