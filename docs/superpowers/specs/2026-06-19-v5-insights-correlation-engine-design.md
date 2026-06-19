# NOOP v5 — Insights & Correlation Engine design

**Pillar:** A personal **n-of-1 correlation / effect engine** — "what actually moves *your* recovery" —
plus the headline sub-feature: a personalised **alcohol / caffeine dose-response** model and an evening
**Damage Forecast** ("a 2nd drink now ≈ −7 Charge tomorrow; coffee after 2 pm ≈ −11 ms HRV").

**Status:** Design only. Not approved. 2026-06-19.

**One-line framing:** Competitors (WHOOP Journal / Behaviors, Oura Tags) show **population** averages —
"alcohol typically lowers recovery." NOOP computes the effect **on your own data, on-device**, ranks the
behaviours *you* log by their real lag-aware effect on next-day Charge / HRV / Rest, gives each one an
effect size + confidence + lead/lag, fits a personal dose curve that shrinks toward a population prior
until you have enough days, and — at night, when it can still change the outcome — tells you what *one
more* of a thing is likely to cost *you* tomorrow. All of it is "patterns in your own data," never advice
or a causal/diagnostic claim.

---

## Goal & differentiation (why only NOOP)

| Capability | WHOOP | Oura | Garmin / Apple | **NOOP v5** |
|---|---|---|---|---|
| Behaviour → recovery effect | Population averages ("Behaviors") | Population tag insights | None / generic | **Per-user effect size, ranked, on-device** |
| Lead/lag awareness (today's drink → *tomorrow's* recovery) | Implicit, fixed | No | No | **Explicit D+1/D+2 lag search per behaviour** |
| Personal dose-response (1 vs 2+ drinks; caffeine timing) | No | No | No | **Per-user dose curve, population-prior shrinkage** |
| Evening "what will one more cost me" | No | No | No | **Damage Forecast on tonight's Charge band** |
| Honest subjective-vs-biometric disconnect | No | "readiness" only | No | **Flags when your mood/readiness diverges from your body** |
| Runs with no account / no cloud / no subscription | No | No | No | **Yes — fully local** |

The differentiation is **not** a new statistic. It is that NOOP already *owns the raw daily series on-device*
(Charge / HRV / Rest / RHR from `IntelligenceEngine`, the journal yes/no tags, the mood check-ins, the
workout tags) and already ships a tested correlation/effect substrate (`BehaviorInsights`,
`ActivityCostEngine`, `CorrelationEngine`, `ComparisonEngine`). v5's job is to **unify those into one
ranked "what moves you" engine**, add the **lag search** and the **dose-response curve + evening forecast**,
and present it honestly. No competitor can match the evening forecast without (a) on-device per-user data
and (b) an on-device recovery model — NOOP has both.

**Honesty is the product.** Where the population says "drinking is bad" but *your* eight logged drink-nights
show no Charge dip, NOOP says so ("we can't see an effect in your data yet"). Where your subjective readiness
or mood says "great" but HRV/RHR say otherwise, NOOP surfaces the **disconnect** rather than picking a side.

---

## Data & signals used (already available vs new)

### Already available (reuse, do not rebuild)
- **Daily outcome series**, keyed `yyyy-MM-dd` in the `metricSeries` store (+ `DailyMetric` columns as a
  strap-only fallback, exactly as `InsightsView.load()` already does):
  - `recovery` (Charge 0–100), `hrv` (ms), `sleep_performance` (Rest 0–100), `rhr` (bpm).
- **Journal behaviour tags** — `JournalEntry (deviceId, day, question, answeredYes)`. Native answers under
  `noop-journal`, imported (WHOOP export) under `my-whoop`; merged with native-wins. Starter catalog already
  includes "Did you drink any alcohol?" and "Did you have caffeine late in the day?".
- **Mood check-ins** — `MoodStore` / `noop-mood`, key `mood`, 1–5 per local day (the subjective signal).
- **Workout tags** — `WorkoutRow (sport, startTs…)`, already shaped into `[sport: Set<day>]` for
  `ActivityCostEngine`.
- **Engines:** `BehaviorInsights` (Welch t-test, Cohen's d, ranking, plain-English sentence),
  `ActivityCostEngine` (D+1 next-morning means + bounce-back trajectory + `ScoreConfidence`),
  `CorrelationEngine` (`pearson`, `alignByDay`, `lagged`, `shiftDay`), `ComparisonEngine`,
  `RecoveryForecaster` (tonight's Charge band from baseline + strain debt + planned sleep), `ScoreConfidence`.

### New (this pillar adds)
1. **A behaviour *dose* signal.** Journal is currently binary yes/no. We add an **optional quantity** to a
   behaviour answer (e.g. drinks: 0/1/2/3+; caffeine: a time-of-day bucket) so dose-response has an x-axis.
   Stored back-compatibly (see Architecture) so existing yes/no history still works (yes ⇒ dose ≥ 1).
2. **A unified lag-aware effect ranker** (`EffectRanker`) that runs every logged behaviour against every
   outcome across a small **lag set {0, +1, +2 days}**, keeps the lag with the strongest honest effect, and
   ranks them — generalising `ActivityCostEngine`'s single-sport D+1 to all journal behaviours + all outcomes.
3. **A per-user dose-response model** (`DoseResponseEngine`) — a shrinkage estimate of "effect per extra unit"
   that blends the user's own slope with a conservative **population prior** weighted by how much data they
   have (so it degrades to the prior with one night and to the personal fit with many).
4. **An evening Damage Forecast** (`DamageForecast`) — takes tonight's `RecoveryForecaster` Charge band and
   applies the dose-response deltas for the behaviours the user is about to log ("if I have a 2nd drink…"),
   producing a *band shift* with confidence, surfaced on Today in the evening only.
5. **A subjective-vs-objective disconnect read** (`DisconnectDetector`) — when the user's mood/readiness
   percentile diverges from their HRV/RHR percentile beyond a threshold over a window, flag it honestly.

No new raw sensor work — this pillar is pure derived analytics over series NOOP already computes.

---

## On-device algorithm (grounded)

All math is **pure, deterministic, DB-free**, self-contained (no special-function tables), and mirrored
value-for-value in Kotlin — the house style of `CorrelationEngine` / `BehaviorInsights` / `ActivityCostEngine`.

### 1. Lag-aware effect ranking (`EffectRanker`)

**Approach (cite):** lag-aware n-of-1 effect estimation in the spirit of VAR / Granger-style temporal
association (cf. PMC9823534 — using day-lagged wearable series to estimate which behaviours precede changes
in recovery), but kept to a **transparent, small fixed lag set** rather than a fitted VAR (honest about n).

For each `(behaviour b, outcome o, lag L ∈ {0, 1, 2})`:
1. Build `behaviourDays = { day : b logged with dose ≥ 1 }` and `outcomeByDay` (reusing the existing load).
2. **Shift** the outcome back by `L` days via `CorrelationEngine.shiftDay` so behaviour day `D` is paired
   with outcome day `D+L` (today's drink → tomorrow's recovery for `L=1`). This is exactly the alignment
   `ActivityCostEngine` already does for D+1 — we parameterise the lag and reuse it.
3. Call the **existing** `BehaviorInsights.effect(...)` on the shifted map → `meanWith`, `meanWithout`,
   `delta`, `pctChange`, `cohensD`, Welch `pApprox`, `significant` (already guards `min(nWith,nWithout) ≥ 5`).
4. Keep, per `(b, o)`, the lag `L*` with the **largest |cohensD|** among lags whose `n` clears the gate; carry
   `L*` as the "lead/lag" (e.g. "shows up the next morning").

Rank with the existing rule (significant first, then |d| desc, stable tiebreak). The output is a
`RankedEffect { behaviour, outcome, lag, BehaviorEffect, confidence }` list — one ranked "what moves your
Charge" feed. `ScoreConfidence` rides each row from `n` (calibrating < gate, building < ~10 paired,
solid ≥ ~10) so a thin behaviour reads honestly instead of shouting.

**Multiple-comparisons honesty.** Searching 3 lags × N behaviours × 4 outcomes inflates false positives. We
**do not** publish raw p < 0.05 as "significant." Instead: (a) report effect size + n + confidence as the
primary signal (an effect-size-first stance — Cohen's d, not stargazing); (b) apply a simple
Benjamini–Hochberg style ordering within an outcome before showing the "SIGNIFICANT" pill; (c) cap the lag
search at the small fixed set so the comparison count stays bounded and explainable. Copy never says
"causes."

### 2. Personal dose-response with population-prior shrinkage (`DoseResponseEngine`)

**Approach (cite):** a per-user fit that **shrinks toward a population prior** (empirical-Bayes /
James–Stein style shrinkage), so one night of data leans on the prior and many nights lean on the personal
slope. This is the standard small-n remedy and keeps early estimates from over-fitting a single bad night.

For a dosed behaviour (alcohol drinks; caffeine = a "late-caffeine intensity" proxy from the time bucket):
1. Collect points `(dose_d, outcome_{d+1})` for each logged day with a next-day outcome (reuse the L=1
   alignment). Doses are small integers (0,1,2,3+ ⇒ 0,1,2,3).
2. Fit the **personal slope** `β_user` = OLS slope of outcome on dose via `CorrelationEngine.pearson`'s slope
   (already returns `slope`/`intercept`); `n_user` = paired days.
3. **Shrink** toward a conservative documented **population prior** `β_prior` (e.g. alcohol ≈ −X Charge pts /
   drink; late caffeine ≈ −Y ms HRV — values are *priors*, surfaced as such, never as a personal claim):

   `β = w · β_user + (1 − w) · β_prior`, where `w = n_user / (n_user + k)` (k = shrinkage constant ≈ 8, the
   pseudo-count of "prior days"). With `n_user = 0`, `β = β_prior`; with `n_user ≫ k`, `β → β_user`.
4. Report per **incremental unit**: `Δ(dose → dose+1) = β` (clamped to a sane range), plus the personal
   curve points for the chart, plus a `ScoreConfidence` from `n_user` and `w` (calibrating when basically all
   prior; building when blended; solid when personal dominates with enough nights).

**Honesty rules baked in:**
- Below the gate (`n_user < minDoseDays`, ≈ 5) the card says **"based mostly on typical patterns, not yet
  yours"** and shows the prior explicitly.
- When the **personal** slope contradicts the prior with enough data (e.g. your drink-nights show *no* dip),
  NOOP says **"in your data so far, this doesn't move your Charge"** — population is not allowed to override
  the person once the person has spoken.
- Caffeine "dose" is a **timing** proxy (later = stronger), not mg; copy is explicit about that.

### 3. Evening Damage Forecast (`DamageForecast`)

**Approach:** compose the existing `RecoveryForecaster` (tonight's Charge point + band from baseline mean/SD
/ slope + strain debt + planned sleep) with the dose-response Δs. This is a *what-if on a number NOOP already
forecasts*, not a new model.

`forecast(base: RecoveryForecast, pending: [(behaviour, fromDose, toDose)]) -> DamageForecast`:
1. Start from `base.charge` and `base.band` (already computed for Today).
2. For each pending behaviour change, look up `DoseResponseEngine.delta(behaviour, outcome=recovery)` and sum
   the incremental Δs (e.g. going 1→2 drinks adds one `β`).
3. Produce `projectedCharge = clamp(base.charge + ΣΔ, 0, 100)` and **widen the band** by the dose model's
   uncertainty (so a low-confidence dose effect shows as a wide, honest range, not a precise scary number).
4. Confidence = min of the forecast's and the dose model's tiers.

Output sentence pattern (wellness, conditional, your-data): *"A 2nd drink tonight tends to line up with
about **−7** on tomorrow's Charge for you (range −3 to −11). Based on 9 of your drink-nights."* When still on
the prior: *"…about −7 based on typical patterns — log a few nights and this becomes yours."*

The forecast is **only shown in the evening** (a time-of-day gate, reusing the local-day machinery) because
that is the only window where it can change behaviour; mornings show the realised effect instead.

### 4. Subjective ↔ objective disconnect (`DisconnectDetector`)

**Approach (cite):** subjective readiness and HRV-based readiness frequently **diverge** (cf. MDPI
*Sports* 2026, 26/4/1325 — perceived recovery vs HRV often disagree); the honest move is to surface the
divergence, not to "correct" one with the other.

Over a trailing window (≈ 21 days): convert the user's **mood** (or, later, a subjective-readiness tag) and
their **HRV/RHR** to within-person **percentiles**; if the rolling subjective percentile and objective
percentile diverge beyond a threshold for several days, emit a neutral read: *"Your mood has been running
higher than your body's signals this week — worth noticing, not a verdict."* Tinted **neutral** (mood is
self-knowledge, never scored good/bad — matching the existing Mind section's deliberate neutrality).

---

## Architecture & files (engine package + Kotlin twin + UI)

**Reuse-first.** Most of this pillar is *new engines that call existing ones* + UI that extends the existing
Insights screen. No rewrites of `BehaviorInsights` / `CorrelationEngine` / `ActivityCostEngine`.

### Shared Swift engine — `Packages/StrandAnalytics/Sources/StrandAnalytics/`
| New file | Responsibility | Calls / reuses |
|---|---|---|
| `EffectRanker.swift` | Lag-aware `(behaviour × outcome × lag)` ranking → `[RankedEffect]` | `BehaviorInsights.effect`, `CorrelationEngine.shiftDay`, `ScoreConfidence` |
| `DoseResponseEngine.swift` | Per-user slope + population-prior shrinkage; per-unit Δ + curve points | `CorrelationEngine.pearson` (slope/intercept), `ScoreConfidence` |
| `DoseResponsePriors.swift` | The documented, conservative population priors (data, clearly labelled "typical, not yours") | — |
| `DamageForecast.swift` | Compose `RecoveryForecast` + dose Δs into a projected band | `RecoveryForecaster`, `DoseResponseEngine` |
| `DisconnectDetector.swift` | Within-person percentile divergence (mood/readiness vs HRV/RHR) | `ComparisonEngine` helpers, `CorrelationEngine` |

Tests (mirror the existing one-test-per-engine layout under `Tests/StrandAnalyticsTests/`):
`EffectRankerTests`, `DoseResponseEngineTests`, `DamageForecastTests`, `DisconnectDetectorTests`.

### Kotlin twin — `android/app/src/main/java/com/noop/analytics/`
Line-for-line ports: `EffectRanker.kt`, `DoseResponseEngine.kt`, `DoseResponsePriors.kt`, `DamageForecast.kt`,
`DisconnectDetector.kt`, with JVM tests under `android/app/src/test/java/com/noop/analytics/` mirroring the
Swift cases (the established cross-platform parity discipline). All engines already have Kotlin twins
(`ActivityCostEngine.kt`, `RecoveryForecast.kt`, `ScoreConfidence.kt`, etc.) so the call sites exist.

### Dose storage (back-compatible)
The journal natural key is `(deviceId, day, question)` with a boolean `answeredYes` — **unchanged**. Dose is
stored as a **separate, optional** `metricSeries` row under a dedicated source `noop-journal-dose`, key =
the question's normalised key, value = the dose integer (mirrors how `MoodStore` parks mood in `metricSeries`
under `noop-mood`). This means:
- Existing yes/no history needs no migration: a logged "yes" with no dose row ⇒ dose = 1.
- A CSV/Health re-import can never overwrite a dose (separate source id — same isolation rule the journal and
  mood already use).
- The cross-platform storage contract stays identical (Swift `upsertMetricSeries` ↔ Kotlin
  `repo.upsertMetricSeries`), so export/import round-trips losslessly.

### UI per platform (extend, don't replace)
- **Swift:** extend `Strand/Screens/InsightsView.swift`. The screen already hosts Journal logging, Mind, the
  Personal Experiment, Behaviour Effects, Activity Cost, and Metric Relationships. We **upgrade** "Behaviour
  Effects" to read from `EffectRanker` (so each card shows the best lag + confidence), **add** a Dose-Response
  card (alcohol/caffeine curve), and surface the **Damage Forecast** on `Strand/Screens/TodayView.swift` in
  the evening. Disconnect read sits in the Mind/Insights neutral zone.
- **Kotlin:** mirror in `android/app/src/main/java/com/noop/ui/InsightsScreen.kt` + `TodayScreen` evening card,
  reusing `NoopCard`/`StatTile`/`SectionHeader`/`JournalChip`.
- **iOS:** the Swift package + non-excluded `Strand/` SwiftUI files cover iOS automatically (shared package +
  shared screens), per the cross-platform parity rule — no separate iOS port beyond verifying the build.

---

## Cross-platform plan

1. **Engines first, both platforms, test-locked.** Write `EffectRanker` / `DoseResponseEngine` /
   `DamageForecast` / `DisconnectDetector` in Swift with tests; port to Kotlin with mirrored JVM tests;
   confirm identical outputs on shared fixtures (the parity discipline that caught the v2.6.0 integration bugs).
2. **Dose storage** added to both repositories under `noop-journal-dose` with identical keys.
3. **UI** wired per platform (mac/iOS share the Swift screens; Android Compose mirror).
4. **Central build-verify all three** once (mac universal, iOS via app-build CI, Android clean assemble) —
   agents don't each run gradle. Back out any half-done lane to keep parity if a wave fails.
5. **Value-for-value:** day-key math via `shiftDay`/local-midnight, the dose contract, the priors table, and
   every threshold constant are identical across Swift/Kotlin so a future sync round-trips.

---

## UX (screens/flows per platform — honest + skimmable)

### Insights screen (mac / iOS / Android) — upgraded
- **What moves your Charge** (was "Behaviour Effects"): the ranked `EffectRanker` feed. Each card: behaviour
  name, the sign-aware plain-English sentence (reuse `BehaviorInsights.sentence`), with/without means as
  `StatTile`s, **lead/lag chip** ("next morning" / "same day"), effect-size word, and a **confidence pill**
  (Solid / Building / Calibrating) — *not* a bare "significant" stamp. Outcome chooser stays the existing
  segmented Charge / HRV / Rest / RHR control.
- **Dose-response card** (alcohol / caffeine): a small curve (dose on x, outcome on y) with the personal
  points plotted and the shrunk line drawn; a one-line read ("each extra drink ≈ −N for you" / "…typical");
  the confidence pill; and the honesty banner when still prior-dominated. Caffeine card states it's *timing*,
  not mg.
- **Disconnect read** (neutral): one line when mood/readiness and biometrics have diverged for the week.
- Existing **Personal Experiment**, **Activity Cost**, **Metric Relationships**, **Mind**, **Journal** cards
  stay; Journal log gains an optional dose stepper on dosed questions (0 / 1 / 2 / 3+), hidden for plain
  yes/no questions.

### Today screen — Damage Forecast (evening only)
A single dismissible card, shown only in the evening: *"Thinking about a nightcap? A 2nd drink tonight tends
to line up with about −7 on tomorrow's Charge for you (−3 to −11)."* with a tiny dose stepper to preview 1 vs
2 vs 3 drinks, the projected Charge band, and the confidence pill. No nags, no streak-shaming. Mornings show
the **realised** effect ("Last night you logged 2 drinks; this morning's Charge came in at the low end of your
range") rather than the forecast.

### Empty / cold-start states (honest, no dead-ends)
- No journal yet → the existing "log behaviours above" copy; dose cards hidden until a dosed behaviour exists.
- Thin behaviour → "Calibrating — keep logging" instead of a fabricated number.
- Prior-only dose → explicit "typical patterns, not yet yours."
- Strap-only user (no import) → outcomes fall back to `DailyMetric` columns exactly as `InsightsView` already
  does, so the engine works account-free.

---

## Non-clinical / legal framing (wellness-only)

- Everything is framed as **"patterns in your own data,"** never advice, diagnosis, or causation. Copy uses
  "tends to line up with," "in your data so far," "worth noticing" — never "causes," "diagnoses," "you should."
- **Effect ≠ cause.** Cards never claim a behaviour *causes* a change; they report an **association** with an
  effect size, n, and confidence, and say so.
- **Population priors are labelled as priors** — "typical patterns," not a statement about the user — and are
  always overridable by the user's own data once it exists.
- **Alcohol / caffeine** are treated as wellness logging, not health advice; the Damage Forecast is a
  *what-if on your own numbers*, never a recommendation to drink or abstain, and never a medical warning.
- **Disconnect read** is explicitly *not* a clinical assessment; mood stays neutral-tinted (self-knowledge,
  not a score), mirroring the existing Mind disclaimer ("Self-tracking, not a clinical assessment. If low
  mood persists, talk to a [professional].").
- **Honest about limits** everywhere: small-n, confounding, "this is association on a handful of days," wide
  bands when uncertain. Reuses the app-wide "approximations, not WHOOP's scores / not a medical device"
  disclaimer.
- **No AI mention.** None of this is described as AI/ML in shipped copy; it is "your data," "patterns,"
  "effect size." (The only AI surface in the app remains the opt-in bring-your-own-key AI Coach.)
- **USD** in any examples ("WHOOP $300–480/yr vs free"); never GBP.

---

## Test plan

- **`EffectRanker`:** a planted lag-1 effect (behaviour day D depresses outcome D+1) is found at L=1 with the
  right sign and beats L=0/L=2; the gate (`min(nWith,nWithout) ≥ 5`) suppresses thin behaviours; ranking
  order (significant-first, |d| desc, stable tiebreak) matches `BehaviorInsights.rank`.
- **`DoseResponseEngine`:** `n_user = 0` ⇒ returns the prior exactly; large `n_user` with a planted slope ⇒
  recovers ≈ the personal slope; the shrinkage weight `w = n/(n+k)` is exact at boundary n; a personal slope
  that contradicts the prior flips the copy state once over the gate.
- **`DamageForecast`:** projected Charge = base + ΣΔ within band; band widens with dose uncertainty;
  confidence = min(forecast, dose) tier; clamps at 0/100.
- **`DisconnectDetector`:** synthetic series where mood runs high while HRV runs low triggers the flag;
  aligned series do not; window edges handled.
- **Dose storage:** a dose row round-trips under `noop-journal-dose`; a yes/no "yes" with no dose row reads as
  dose = 1; a CSV re-import does not touch dose rows.
- **Cross-platform parity:** Swift and Kotlin produce byte-identical engine outputs on shared fixtures (the
  standing parity gate).
- **No regressions:** existing `BehaviorInsightsTests`, `ActivityCostEngineTests`, `CorrelationEngineTests`,
  `RecoveryForecastTests` stay green (we add, not rewrite).

## Phasing

**MVP (Phase 1)**
- `EffectRanker` (lag {0,1,2}) + the upgraded "What moves your Charge" feed with lead/lag + confidence.
- Optional **dose** on alcohol & caffeine journal questions (storage + stepper).
- `DoseResponseEngine` with population-prior shrinkage + the Dose-Response card (alcohol first).
- Both platforms, tests, central build-verify.

**Phase 2**
- Evening **Damage Forecast** on Today (compose with `RecoveryForecaster`), morning realised-effect line.
- Caffeine dose curve (timing proxy) + more dosed behaviours (late meal portions, etc.).

**Phase 3**
- `DisconnectDetector` subjective↔objective read; optional subjective-readiness tag feeding it.
- Fold the top mover into the existing `WeeklyDigest` focal points.

**Later / out of scope (v1)**
- A fitted VAR / true Granger test (we stay with the bounded lag set for honesty at small n).
- Auto-detected behaviours (no manual log) — stays manual-first per app philosophy.
- Any cloud / cross-user pooling — priors are static, documented constants, never learned from users.

## Open questions

1. **Dose granularity for alcohol** — 0/1/2/3+ buckets vs a free integer? Buckets are simpler and likely
   enough for a personal slope; lean buckets for MVP?
2. **Caffeine "dose"** — confirm the timing-bucket proxy (morning / midday / after-2pm / evening → 0..3) is
   the right x-axis vs an optional cups count.
3. **Population prior values** — what conservative numbers for alcohol-per-drink (Charge) and late-caffeine
   (HRV ms)? Source them from published wearable studies and label them clearly as priors; the maintainer to sign off
   the exact magnitudes.
4. **Multiple-comparisons UI** — show the BH-adjusted "significant" pill, or drop the word "significant"
   entirely in favour of effect-size + confidence only (more honest, less familiar)?
5. **Evening window definition** — fixed local clock (e.g. after 18:00) or learned from the user's typical
   logging/sleep time?
6. **Disconnect default-on?** — surface the subjective↔objective read by default, or keep it opt-in given it
   touches mood?
