# Cognitive Annealing Engine / Directed Plasticity Protocol — NOOP #79

**Status:** Research exploration — governed by [#94](https://github.com/kvnloo/noop/issues/94) (one at a time, bounded, opt-in, ends with receipt). Not product work until graduated through [oss-factory #212](https://github.com/kvnloo/oss-factory/issues/212) gates.

**Scope:** Written protocol + falsification slice only. No production code, no schema, no second store, no medical claims, no "flow score".

**Branch:** `fav/cognitive-annealing-falsification-79` (docs-only, based on `main` @ `2a1de7609843b095505274ad6fc811757210be80` — fork `main` == `ryanbr/noop` `main`).

**Chain position:** #5 of 5 (#76 → #77 → #85 → #84 → **#79**). All four predecessor Draft PRs exist with isolate verdicts recorded:
- #76: PR [#176](https://github.com/kvnloo/noop/pull/176) `fav/experiment-contract-design-76`
- #77: PR [#177](https://github.com/kvnloo/noop/pull/177) `fav/lagged-outcome-semantics-77`
- #85: PR [#178](https://github.com/kvnloo/noop/pull/178) `fav/flow-shield-study-design-85`
- #84: PR [#179](https://github.com/kvnloo/noop/pull/179) `fav/intervention-catalog-recipe-backlog-84`

---

## 1. Purpose and provenance

The August 2026 **Cognitive Annealing Engine**, **Directed Plasticity**, **Plasticity Compiler**, **Temporal Multiplexing**, Project LUCID and Flow Chamber ideas share this hypothesized state sequence:

```
observe state → choose goal/task/mode →
explore → select → encode → consolidate →
validate delayed/unassisted transfer → execute → recover →
update evidence
```

The thesis is **NOT** that acute arousal, neural entropy or psychedelic-like subjective novelty necessarily improves learning; **consolidation and independently verified durable transfer** are the tests. NOOP owns _measured context_ (sleep, readiness, Journal factors, Breathe where applicable); learning protocols are research tools outside NOOP.

This slice writes the **protocol as user-entered steps with a prespecified outcome and lag** (same shape as #76 contract fields and #84 recipe table), the **falsification** (what measured result kills the claim), marks **`NOT_EXECUTED`** for what cannot be measured locally, and states **exit criteria** for graduating into oss-factory #212.

---

## 2. Primitives this slice reuses (cited, not rebuilt)

| Primitive | Where on `main` | Used for |
|---|---|---|
| Journal starter questions | `Strand/Data/JournalCatalog.swift` `starterQuestions`; Android `android/app/src/main/java/com/noop/ui/JournalLog.kt` | **User-entered** state/context factors (Yes/No/Skipped/unanswered distinct) |
| Breathe session | `Strand/Screens/BreathingView.swift`, `StrandAnalytics/BreathProtocolCatalog.swift` | Optional exploration-preparation arm (link per fork PR [#51](https://github.com/kvnloo/noop/pull/51), Android only, not on `main`) |
| Behaviour Effects | `Packages/StrandAnalytics/.../BehaviorInsights.swift` `effect(...)`; Android `analytics/EffectRanker.kt` `effect(...)` | With-vs-without contrast on **explicit-No controls only** |
| Prospective contract / receipts / study design | PR [#176](https://github.com/kvnloo/noop/pull/176) (#76), [#177](https://github.com/kvnloo/noop/pull/177) (#77), [#178](https://github.com/kvnloo/noop/pull/178) (#85) | Locking, lagged outcome objects, falsification-plan pattern |
| External outcome contract | PR [#177](https://github.com/kvnloo/noop/pull/177) §2 (`ExternalOutcomeObservation` 16 fields) | Learning outcomes (transfer, retention, calibration) with `input_tier` |
| Synthetic Journal pilots | Fork PR [#46](https://github.com/kvnloo/noop/pull/46) | Existing witnesses for state-sequence feasibility |

Upstream [ryanbr/noop#1760](https://github.com/ryanbr/noop/issues/1760) and the Benchmark issue [#78](https://github.com/kvnloo/noop/issues/78) are context only.

---

## 3. Protocol — User-Entered Steps with Prespecified Outcome and Lag

Column rules (all reviewer-checkable, same as #84 §2):
- **Step / context** is **user-entered**: an existing Journal question quoted verbatim, or `PROPOSED:` plus a question that does not exist yet. NOOP never infers it from wearable data and never auto-answers it.
- **Baseline / control** is **comparable explicit-No wake-days**: the same question answered No by the same person on wake-days with similar weekday, prior-night sleep and training load. **Unanswered or Skipped days are never controls.** Rows that cannot use explicit-No say what they use instead and why.
- **Outcome + lag** is fixed before the first exposure day. Lag runs from the exposure wake-day to the outcome wake-day.
- **Owner** is the existing NOOP component or external producer that holds the data. It is never a new store.
- **Input tier** (per #79 comment): every observation entering a Directed Plasticity analysis carries `input_tier ∈ { device_measured, imported_source, self_report, agent_inferred }` with `input_basis` free text required for `self_report` and `agent_inferred`. These tiers may be recorded as context but **never promoted into a learning outcome** (`θ`, far transfer, retention) in any `analysis_recipe_version`.

| ID | Step / Context (user-entered) | Baseline / Control | Prespecified Outcome + Lag | Owner | Mode | Exposure Input Tier | Outcome Input Tier | Disconfirming Result |
|---|---|---|---|---|---|---|---|---|
| A1 | **Exploration-preparation**: `PROPOSED:` "Did you complete an exploration-preparation sequence this morning?" (5-min novel microdomain exposure, e.g. unfamiliar pattern, new vocabulary set, novel motor sequence) | Explicit-No mornings (no sequence) on comparable wake-days (matched prior sleep, weekday, training load) | **Primary:** 7-day unassisted far-transfer per learning minute (`learning.far_transfer.7d_per_min`), measured on hold-out novel task; **Secondary:** 24h retention (`learning.retention.24h`), metacognitive calibration (`learning.calibration.brier`), false-memory error (`learning.false_memory.rate`), fatigue (`subjective.fatigue.next_am`), subsequent sleep (`sleep_performance`), lag 7 days for primary, lag 1 for secondary | External learning producer (Anki/FSRS, custom microdomain) via #77 outcome contract | `assignable` (both arms ordinary, low-risk) | `self_report` (Journal) | `device_measured` (external producer) | Predicted: preparation > neutral on primary. **Falsified if:** with ≥5 prep and ≥5 explicit-No days, ≥70% coverage, primary effect ≤ 0 or p ≥ 0.05 (Welch). Below coverage → `inconclusive`. |
| A2 | **Focused encoding** (standardized in all arms): `PROPOSED:` "Did you complete the standardized encoding block today?" (fixed 10-min study of assigned novel material, same for all conditions) | Not a contrast — this is the **held-constant** step. Control is the *absence of A1/A3/A4*, not absence of encoding. | Same outcomes as A1. Encoding quality check: immediate learning (`learning.immediate.accuracy`) lag 0 — must not differ across arms (manipulation check). | External learning producer + NOOP Journal (encoding completion) | `assignable` (standardized task) | `device_measured` (external producer) | `device_measured` (external producer) | If immediate accuracy differs across arms by >5 pp or p < 0.05, the encoding standardization failed → entire protocol `inconclusive`. |
| A3 | **Protected quiet post-learning wake**: `PROPOSED:` "Did you keep a 60-min quiet wake window after encoding?" (no media, no tasks, eyes-open rest or breath protocol only) | Explicit-No days (no quiet window) on comparable wake-days; interference arm = matched disruption (notifications, secondary task) | Same primary/secondary outcomes as A1, lag 7/1 days | NOOP Journal (quiet window Yes/No) + external learning producer | `assignable` (quiet wake is ordinary) | `self_report` (Journal) | `device_measured` (external producer) | Predicted: quiet > interference on primary. **Falsified if:** quiet − interference ≤ 0 on primary at ≥70% coverage, p ≥ 0.05. |
| A4 | **Consolidation sleep**: `PROPOSED:` "Did you sleep ≥7 h with no alarm?" (natural wake, no intentional restriction) | Explicit-No nights (<7 h or alarm) on comparable nights; **season/DST boundary = stop** (per #84) | Same outcomes; sleep architecture proxies if external source consents (EEG `sleep.spindle.density`, `sleep.sw.power`) — context only, never primary | Sleep + external producer (WHOOP/EEG via #44) | `observe-only` (sleep restriction not assigned) | `imported_source` (WHOOP/HealthKit) | `device_measured` (external producer) | Predicted: natural ≥7h > restricted on primary. **Falsified if:** natural − restricted ≤ 0 at ≥70% coverage, p ≥ 0.05. Carry-over check at lag 14: if lag-14 > lag-7, result `inconclusive`. |
| A5 | **Recovery / re-exposure**: `PROPOSED:` "Did you do a 5-min re-exposure (not re-study) on day 3?" (brief cued recall, no feedback) | Explicit-No days (no re-exposure) on comparable wake-days | Same primary outcome (7-day), lag 7 from original encoding | External learning producer + NOOP Journal | `assignable` | `device_measured` (external producer) | `device_measured` (external producer) | Predicted: re-exposure > no re-exposure on primary. **Falsified if:** re-exposure − no ≤ 0 at ≥70% coverage, p ≥ 0.05. |
| A6 | **Full sequence (A1→A2→A3→A4→A5)** vs **Neutral sequence** (A2 only, no A1/A3/A4/A5) | Neutral = explicit-No on A1, A3, A4, A5 on same wake-day; encoding (A2) held constant | **Primary:** 7-day unassisted far-transfer per learning minute (`learning.far_transfer.7d_per_min`), lag 7 from encoding day | External learning producer via #77; NOOP Journal for A1/A3/A4/A5 | `assignable` (all arms ordinary) | mixed (A1 self_report, A2 device_measured, A3 self_report, A4 imported_source, A5 device_measured) | `device_measured` (external producer) | **Core falsification:** full sequence − neutral ≤ 0 on primary at ≥70% coverage, Welch p ≥ 0.05. **Any single component (A1, A3, A4, A5) null/harm also falsifies its individual claim.** Below coverage → `inconclusive`. |

**Statistic (all rows):** existing Behaviour Effects output (mean difference, Welch p, Cohen's d) for NOOP-native outcomes; external learning outcomes use the #77 receipt analysis recipe (predeclared, versioned). No new statistics added.

**Minimum coverage (all rows):** at least 5 exposure and 5 explicit-No control wake-days with a valid outcome row, and at least 70% of trial wake-days covered. Below that the verdict is **inconclusive / unknown**, never "no effect" and never "works".

**Confounds named (per #84, #85):** regression to the mean (predeclared start date, not after bad week), season and DST (no window crosses DST change or season boundary), training load (recorded covariate), expectancy/placebo (measured via `input_tier = self_report` at baseline, used as covariate only), practice effects (novel microdomains randomized per arm, balanced order). No automatic completion from wearable data.

The machine-readable copy is `docs/fixtures/cognitive_annealing_recipes.json`. It is **synthetic**, contains no personal data, and is not imported by the app.

---

## 4. Evidence tier rule (from #84 §3, extended for learning outcomes)

| Tier | Label | Minimum to *display* this tier |
|---|---|---|
| T0 | unknown | default; no outcome or no coverage |
| T1 | anecdote / idea | user-entered factor exists; no prespecified outcome or lag |
| T2 | testable hypothesis | **prespecified outcome key + lag + explicit-No baseline + disconfirming result**, all written in the row before any exposure day |
| T3 | replicated human evidence (external) | T2, plus a citation (DOI or registry ID) in the row that the reviewer has opened |
| T4 | personal N-of-1 result | T2, plus a locked #76 contract (`prediction_locked_at` before day 1) and an adjudicated #77 receipt. The label shows the verdict (`supports` / `contradicts` / `inconclusive`) for **this person only** |

**The rule.** A recipe **may not exceed T1 until it has a prespecified outcome and lag.** It may not show T3 without an opened citation, or T4 without a receipt. T3 and T4 are independent: external replication never upgrades a personal verdict, and a personal verdict is never generalised to other users. This slice includes no citations, so **every row is capped at T2**.

**Additional rule for learning outcomes (per #79):** any observation with `input_tier ∈ { self_report, agent_inferred }` may appear in the receipt as **context or secondary outcome only** and is **excluded from primary learning outcomes** (`learning.far_transfer.7d_per_min`, `learning.retention.24h`, `learning.calibration.brier`, `learning.false_memory.rate`) in every `analysis_recipe_version`. This matches the issue's rule that momentary arousal, vendor attention readings and "neural entropy" are not validated learning outcomes.

---

## 5. Low-risk gate (reviewer-checkable, from #84 §4)

**Excluded outright.** A row in any of these classes is rejected in review, not softened:

1. **Supplements, medication, pharmacology, neurostimulation.** No dose, timing, stack, cycle, titration, interaction, tDCS, TMS, strobe, VR, VRT, eye-tracking rows. Optional external research probes (EEG, VR, VRT, eye tracking, strobe) may be **recorded as `input_tier = device_measured` context** but are never an assigned exposure and never interpreted as established NOOP capability.
2. **Treatment recommendations.** No "if metric X then do Y". The only conditional is the disconfirming result (statistical stop rule).
3. **Medical / cognitive-enhancement claims.** No row says an intervention *improves, treats, prevents, reduces risk* or is *clinically proven*. "Plasticity Compiler", "Directed Plasticity Yield", "neural entropy" are not validated constructs.
4. **Sleep restriction, extreme heat/cold, fasting,** anything whose no-exposure or exposure arm needs medical supervision.
5. **Auto-answered factors.** A wearable reading never writes a Journal Yes or No.
6. **Assigned risk.** An exposure with physical risk is `observe-only` at most (A4 is observe-only).

**How a reviewer checks it** (five greps on this PR's files):

```sh
# 1. no excluded vocabulary in the recipe rows or fixture (expect: no output)
grep -inE 'dose|mg\b|stack|supplement|medicat|treat|prevent|cure|clinically|improves|tDCS|TMS|strobe|VR\b|VRT|eye.track|neural.entropy|plasticity.compiler|directed.plasticity.yield' docs/fixtures/cognitive_annealing_recipes.json

# 2. no row uses unanswered/skipped days as control (expect: no output)
grep -inE '"baseline_control": *"[^"]*(unanswered|unlogged|skipped)' docs/fixtures/cognitive_annealing_recipes.json

# 3. tier ceiling: every fixture row is tier <= 2 (expect: no output)
grep -nE '"evidence_tier": *[3-9]' docs/fixtures/cognitive_annealing_recipes.json

# 4. outcome_input_tier rule: self_report and agent_inferred never appear in primary learning outcome fields (expect: no output)
grep -nE '"outcome_key": *"learning\.(far_transfer|retention|calibration|false_memory)"' docs/fixtures/cognitive_annealing_recipes.json | xargs -I{} sh -c 'jq -r "select(.outcome_input_tier == \"self_report\" or .outcome_input_tier == \"agent_inferred\")" {}'

# 5. exposure vs outcome tier separation: every recipe has both exposure_input_tier and outcome_input_tier (expect: 6 lines, one per recipe)
grep -c '"exposure_input_tier"' docs/fixtures/cognitive_annealing_recipes.json
grep -c '"outcome_input_tier"' docs/fixtures/cognitive_annealing_recipes.json
```

Prose check: every `Step / Context` cell is either a verbatim `starterQuestions` string or starts with `PROPOSED:`.

---

## 6. Falsification Plan — What Measured Result Kills the Claim

Following #85 §2 pattern: **any one criterion sufficient to stop believing the full sequence helps.**

| ID | Criterion | What it means |
|---|---|---|
| **F1** | **Primary endpoint null or harm** in within-person A/B (full sequence vs neutral) with adequate coverage (≥5 per arm, ≥70%) | The core claim — that the state sequence improves 7-day far transfer per learning minute — is not supported. Stop building the annealing engine. |
| **F2** | **Any single component (A1, A3, A4, A5) shows null/harm** on its individual contrast at adequate coverage | The sequence is not additive; the hypothesized phase (explore, consolidate, sleep, re-expose) does not contribute. Reallocate to the next exploration. |
| **F3** | **Immediate encoding differs across arms** (manipulation check fails: >5 pp or p < 0.05 on `learning.immediate.accuracy`) | The "focused encoding standardized in all arms" assumption is violated. The comparison is confounded. Protocol `inconclusive` — redesign encoding standardization. |
| **F4** | **Carry-over dominates** (lag-14 effect > lag-7 effect on primary, or lag-2 > lag-1 on sleep) | The effect is not consolidation but residual interference or delayed expression. Result `inconclusive` for consolidation claim. |
| **F5** | **Expectancy/placebo explains the effect** (baseline `self_report` expectancy covariate renders primary effect ≤ 0 at p ≥ 0.05) | The benefit is belief-mediated, not state-sequence-mediated. The "belief/placebo route to willpower" (per #79 comment) is the active ingredient — redirect to that hypothesis. |
| **F6** | **Missingness / censoring asymmetric** (coverage <70% in one arm, or censoring pattern predicts outcome) | The comparison is not fair. The trial is censored, not failed — documented as `inconclusive` per #85. |

**Non-falsifiable → explicitly acknowledged (from #85):**
- If the study **cannot** be run (no physical device for external learning producer, no consent, EEG/WHOOP export unavailable, external producer API changes), the result is **inconclusive** — not evidence for or against. The design documents this as a censored trial.
- `self_report` and `agent_inferred` tiers are **never promoted** to primary learning outcomes (enforced by #77 receipt logic). A null result on primary with only self-report data is expected, not a falsification of the protocol.

---

## 7. No "Flow Score" / "Plasticity Score" — Explicit Statement & Offsetting Measure

> **We do not ship, compute, or validate a "flow score", "plasticity score", "annealing index", "directed plasticity yield", "neural entropy", "state transition cost", or any composite latent construct.**

All metrics reported are **behavioral proxies** or **direct learning measurements** derived from:
- External learning producers (Anki/FSRS, custom microdomain) via #77 `ExternalOutcomeObservation` with `input_tier = device_measured` or `imported_source`
- NOOP Journal (user-entered state/context) — `input_tier = self_report` (context only)
- NOOP Breathe (session completion) — `input_tier = device_measured` (session timestamp + quality flag)
- NOOP Sleep/Readiness (WHOOP/HealthKit) — `input_tier = imported_source`
- Optional external research probes (EEG, VR, eye-tracking) — `input_tier = device_measured`, **context only**, never a NOOP capability

**No aggregation, weighting, normalization, or thresholding** across these fields produces a single score. Any dashboard showing a composite number is explicitly out of scope and would require a separate validation study (clinical/causal, not observational).

### Offsetting Measure We DO Report

**Within-person randomized A/B effect estimates with censoring-aware confidence intervals** for each outcome separately:
- Primary: `learning.far_transfer.7d_per_min` (full sequence vs neutral, per novel microdomain)
- Component: each of A1, A3, A4, A5 vs its explicit-No control (same design)
- Secondary: `learning.retention.24h`, `learning.calibration.brier`, `learning.false_memory.rate`, `subjective.fatigue.next_am`, `sleep_performance` (lag 1)
- Coverage & censoring rates reported **per condition** (sequence/neutral, component/control) and **per analysis window**

This satisfies the "offsetting measure" requirement: we report **causal-effect estimates on observable proxies** with honest uncertainty, not a validated latent construct.

---

## 8. Exit Criteria → oss-factory #212 Gates

Graduation is through [oss-factory #212](https://github.com/kvnloo/oss-factory/issues/212)'s gates (#94 rule 6): **M2+** for learning comparisons, **M3** for context/health signals, **M4** for adaptive policy.

| # | Criterion | Gate | How verified |
|---|---|---|---|
| **G1** | **Two-workflow evidence (M2+).** Two independent genuine user workflows that cannot be expressed losslessly through existing Journal + Behaviour Effects + external outcome contract are demonstrated and recorded in #79, with alternatives tried first. | M2+ | Two fixture JSON files (one per workflow) that fail a lossless round-trip through current NOOP primitives; recorded in #79. If both expressible losslessly → ship no contract, close exploration. |
| **G2** | **Invariant repaired on `main` (M3).** The #76 §4 violation (explicit-No baseline in Experiment card) is fixed on both platforms from the explicit-No set, with pure deterministic selection helpers and matching synthetic vectors on Swift and Kotlin, cross-platform parity asserted by oracle. | M3 | #49 repair merged to `main`; gate isolate + union pass on the repair PR. |
| **G3** | **Locked contract + adjudicated receipt.** A #76 contract with outcome, lag, comparator, minimum coverage and stop date, locked before day 1 (`prediction_locked_at`); a #77 receipt with verdict `supports`/`contradicts`/`inconclusive` from the predeclared rule. Low coverage → `inconclusive`. | M2+ | Contract + receipt artifacts exist on the slice branch; receipt verdict matches predeclared rule. |
| **G4** | **Falsification plan executed.** At least one falsification criterion (F1–F6) has been tested with adequate coverage and the result recorded (including `inconclusive`). | M2+ | Receipt shows which F-criterion was tested and the observed result. |
| **G5** | **Input tier invariant enforced.** No `self_report` or `agent_inferred` observation appears in primary learning outcome fields in any receipt on this branch. | M3 | Static analysis: grep for `input_tier` in primary outcome observations → empty. |
| **G6** | **Fork gates on the exact head.** `noop-channel gate isolate` on the slice's own head, then `gate union` on a throwaway union ref that is never pushed, never merged, never targeted. `BLOCKED` or `NOT_EXECUTED` recorded as such, never as `PASS`. | All | Verdict JSONs posted as PR comments. |
| **G7** | **Human burden stated and bounded.** Reading existing Journal questions + optional Breathe session. This slice adds **0 new minutes/day** (reuses questions user already answers; Breathe is opt-in, default OFF, no notification). Any graduation adding a surface must restate this line. | All | Burden line in PR body and this doc §3. |
| **G8** | **Stop date.** This exploration stops on **2026-11-21**. If G1 evidence not collected by then, exploration is dropped or re-scoped in #79; result kept (#94 rule 5: negative results kept, not deleted). | All | Date in PR body; #79 comment records keep/revise/drop. |

---

## 9. Cheapest Falsifiable First Trial

**A1 (Exploration-preparation) → `learning.far_transfer.7d_per_min`, lag 7, explicit-No controls.**

Why it is the cheapest:
- The `PROPOSED:` question is a single new Journal starter question (one line in catalog).
- Behaviour Effects already uses explicit-No controls; needs **no code and no #49 repair**.
- External learning producer (Anki/FSRS or custom microdomain) already emits #77-compatible observations per fork tooling.
- Both arms are ordinary and low-risk; burden is ~15 s/day (answer one Journal question + run 10-min encoding block).
- Fork PR #46 already has synthetic witnesses for novel microdomain exposure.

**Prediction (locked before day 1 via #76 contract):** preparation days have higher 7-day unassisted far-transfer per learning minute than explicit-No days.

**Falsified if (F1):** with at least 5 preparation and 5 explicit-No wake-days and at least 70% coverage, primary effect ≤ 0 or Welch p ≥ 0.05. With less coverage → `inconclusive`.

**If F1 observed:** stop building the annealing engine; reallocate to next exploration (#94 rule 1). Record receipt in #79: what was tried, what was observed, what is now believed, **keep / revise / drop**.

---

## 10. NOT_EXECUTED — What Cannot Be Measured Locally

| Item | Reason | How it would be measured (outside this slice) |
|---|---|---|
| `learning.far_transfer.7d_per_min` (primary outcome) | Requires external learning producer (Anki/FSRS, custom microdomain) with hold-out novel-task transfer test. NOOP has no learning engine. | `kvnloo/anki`, `kvnloo/fsrs4anki`, or custom microdomain tooling emits #77 `ExternalOutcomeObservation` with `outcome_key = learning.far_transfer.7d_per_min`, `input_tier = device_measured`, `measurement_protocol` = far-transfer test vX.Y.Z. |
| `learning.retention.24h`, `learning.calibration.brier`, `learning.false_memory.rate` | Same — external producer only. | Same as above with respective `outcome_key`s. |
| EEG sleep architecture (`sleep.spindle.density`, `sleep.sw.power`) | Requires EEG hardware + consent; not a NOOP sensor. | Optional external probe; `input_tier = device_measured`, `source_id = eeg_research_probe`, recorded as context only (never primary). |
| VR / VRT / eye-tracking / strobe probes | Optional external research probes; not NOOP capabilities. | Same as EEG — context only, `input_tier = device_measured`, never assigned exposure. |
| `input_tier = self_report` expectancy/placebo baseline | User-entered; NOOP records it but cannot validate it as a learning outcome. | Journal question `PROPOSED:` "How confident are you that today's preparation will help?" (1–7); recorded as context covariate only. |
| `input_tier = agent_inferred` attention/arousal proxy | Agent inference; explicitly barred from primary outcomes per #79 comment. | If an agent infers attention from telemetry, it is logged with `input_tier = agent_inferred`, `input_basis = "..."`, used only as secondary context. |
| Durable preregistration proof (`prediction_locked_at` before exposure) | Pure type cannot prove lock-before-exposure; needs independent persistence (signed hash, write-once log, external timestamping). | Documented as `NOT_EXECUTED` — the #76 contract design notes this; a real implementation would need an external timestamping service or local write-once log. |

**These are not failures of the protocol.** They are explicit boundaries: NOOP provides measured context and consented scalar outcomes; learning protocols and validation are external. The protocol is falsifiable *when* the external producer exists — the falsification criteria are written *before* that producer is available.

---

## 11. Reconciliation with Predecessor Slices

| Slice | What #79 adopts | What #79 extends |
|---|---|---|
| **#76 (PR #176)** | Prospective contract fields (baseline/exposure/outcome windows, `predicted_direction`, `minimum_coverage`, `minimum_samples`, `predeclared_support_and_falsification_rule`, `prediction_locked_at`, `analysis_recipe_version`, `status`) | Adds learning-specific outcome keys (`learning.far_transfer.7d_per_min`, etc.), `input_tier` on observations, multi-phase sequence (A1–A6) as a single contract with component sub-contrasts |
| **#77 (PR #177)** | `ExternalOutcomeObservation` 16 fields + validation rules; receipt separation invariant; `measurement_kind` as discriminant | Adds `input_tier` field (required, not optional) to the observation object; hard rule: `self_report`/`agent_inferred` excluded from primary learning outcomes in all `analysis_recipe_version`s |
| **#85 (PR #178)** | Falsification plan pattern (F1–F6); no-composite-score statement; offsetting measure (within-person A/B); censored-trial acknowledgment | Extends to multi-component sequence with component-level falsification (F2); adds carry-over check (F4); adds expectancy covariate check (F5) |
| **#84 (PR #179)** | Recipe table shape (user-entered, explicit-No baseline, outcome+lag, owner, tier ceiling, disconfirming result); low-risk gate greps; T2 cap | Adds `input_tier` column; learning outcomes (not just sleep/HRV/recovery); multi-phase sequence as 6-row protocol; observe-only mode for sleep (A4) |

The master reconciliation table from #76 (§5 of PR #176) remains the single source of truth for held draft dispositions (#42/#43/#44). This slice adds no new row; it only applies the #77 observation schema and #84 recipe shape to the Cognitive Annealing hypothesis.

---

## 12. Evidence Index

Every claim above is reproducible. Base: `kvnloo/noop` `main` at head **`2a1de7609843b095505274ad6fc811757210be80`** — pinned by `git rev-parse HEAD` in the slice checkout, `gh api repos/kvnloo/noop/commits/main --jq .sha` and `gh api repos/ryanbr/noop/commits/main --jq .sha` (fork `main` is the exact mirror: all three SHAs agree).

| Claim | How it was checked |
|---|---|
| The four #76 symbols exist on current `main` | `grep -rn` over `Packages/`, `Strand/`, `android/` (paths in #76 §4) |
| Behaviour Effects uses explicit-No controls | `EffectRanker.kt:242`; `BehaviorInsights.swift:99` — day in neither set is skipped |
| Experiment card baseline still counts unlogged days | `InsightsView.swift:814`; `buildExperimentSnapshot` in `InsightsScreen.kt` |
| Journal starter questions exist on both platforms | `JournalCatalog.swift` `starterQuestions`; `JournalLog.kt` |
| Breathe session + BreathProtocolCatalog exist | `BreathingView.swift`; `BreathProtocolCatalog.swift` |
| Fork PR #46 synthetic witnesses exist | `gh pr view 46 --repo kvnloo/noop` — open, has synthetic Journal pilots |
| Fork PR #51 Breathe→Journal link exists | `gh pr view 51 --repo kvnloo/noop` — open, Android only |
| Runner state at time of writing | `gh api repos/kvnloo/fleet-runner/actions/runs --jq '.workflow_runs[0].conclusion'` → latest run conclusion (budget-cancellable, not red) |
| No executable suite matches a docs-only change | `noop-channel gate isolate` on PR #176 returned `BLOCKED` with "no executable suite matches this PR's paths" |

This slice itself is **not** covered by any executable gate: a documentation-only change matches no suite in `noop-channels/gates.py`'s path table, so `noop-channel gate isolate` will record **`BLOCKED`** with the note "no executable suite matches this PR's paths" (`gates.gate_isolate` refuses to claim a verdict it could not produce). That is recorded rather than papered over, and it is never written as `PASS`.

---

## 13. Not in Scope

Issue #79 and #94 forbid these, and this slice does not add any of them:

- a **second Journal**;
- a **second metric store**;
- a **protocol database**;
- a **product-level experiment dashboard**;
- production code, schema/migration changes, persistence, a scheduler;
- result or effect calculation, causal inference, a response model, a recommendation system;
- automatic treatment recommendation, hosted service, cloud telemetry, clinical efficacy claim;
- silent P0–P4 promotion (the held drafts stay held per #76 §5);
- "Plasticity Compiler", "Directed Plasticity Yield", "neural entropy", "state transition cost" as computed/validated scores;
- neurostimulation, pharmacological, or clinically-acting intervention of any kind;
- sleep restriction, extreme heat/cold, fasting as assigned exposures.

Upstream implementation ownership and contributors are preserved; upstream posting stays owner-gated through `upstream-gate/gate propose`.

---

## 14. What This Slice Asks For

Nothing but a decision recorded in #79: given the protocol in §3, the falsification plan in §6, the `NOT_EXECUTED` boundaries in §10, and the exit criteria in §8 — does the factory work the **two-workflow evidence (G1)** as the next active exploration, or first repair the **explicit-No invariant (G2)**? Both are cheap; only one may be active at a time (#94 rule 1). The cheapest first trial is A1 (§9).