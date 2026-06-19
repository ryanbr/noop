# NOOP v5 — Skin-Temperature Suite (codename Strand)

**Pillar:** Three on-device features built on the underused **skin-temperature** signal — (1) **Cycle Phases** (menstrual / ovulatory / luteal awareness), (2) **Body Clock** (circadian-phase / jet-lag / shift-work optimiser), (3) **Heads-Up** (honest illness early-warning with false-positive suppression).

**Status:** Design only. Not approved. No code yet.

**One-line thesis:** WHOOP already streams skin temperature every night and NOOP already banks it (`skin_temp_raw@73`, centidegrees, wear-gated to a nightly mean) — but today NOOP only uses it as a 5% term in Charge and a flag in the illness banner. Three of the most-requested, most-validated wearable features fall straight out of that one signal when you reason from it properly. NOOP computes them **entirely on-device, free, and private** — the same things Oura sells as a paid cloud subscription and a "future feature" roadmap.

---

## Goal & differentiation (why only NOOP)

Skin temperature is the most information-dense passive signal a wrist wearable collects and the **least exploited** by every consumer app. The competitors that do use it ship it as a cloud, paywalled, account-bound feature:

| Feature | Who sells it | How they sell it | NOOP v5 |
|---|---|---|---|
| Cycle / period prediction | Oura (flagship), Natural Cycles, Apple (Cycle Tracking) | Cloud AI, **paid subscription** (Oura), account + data upload | **Free, on-device, never leaves the wrist** |
| Circadian / jet-lag / shift advice | Almost nobody at consumer scale (Timeshifter is a separate paid app with no wearable data; Oura has a thin "optimal bedtime") | Generic, not derived from *your* temperature minimum | **Derived from YOUR nightly temp minimum + rest-activity, on-device** |
| Illness early-warning | Oura ("Symptom Radar"), WHOOP ("Health Monitor") | Cloud, opaque, prone to crying wolf | **On-device, multi-signal, with explicit false-positive suppression and a "why"** |

**Why structurally only NOOP can offer all three free + private:**

- **We already have the raw signal banked locally.** No competitor exposes the raw nightly skin-temp series to the user, let alone three derived products off it. NOOP's whole architecture is local raw → on-device engine.
- **No cloud, no account, no subscription.** Reproductive-health data and illness signals are the single most sensitive category of health data a person owns. NOOP's selling point is the one thing a cloud product *cannot* promise: **this data is physically never transmitted.** That is the headline, not a footnote.
- **We reason from raw signals + fuse them.** Cycle phase isn't temperature alone — it's temperature **+** the luteal resting-HR rise **+** the luteal HRV drop **+** (optionally) respiration. NOOP already computes all four nightly metrics and their personal baselines. The fusion is the moat; a single-signal product is weaker.
- **Honesty as a feature.** Every competitor over-claims. NOOP's differentiator is calibrated humility: "awareness, not prediction"; "a heads-up to rest, not a diagnosis"; explicit confidence tiers and a visible "why this fired."

---

## Data & signals used (what's already available vs new)

### Already available (reuse, no new capture)

All four nightly inputs are **already computed and persisted per local day** in `DailyMetric` (`Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift`):

- **`skinTempDevC`** — nightly skin-temp **deviation** (±°C) from the personal baseline. Computed in `AnalyticsEngine.analyzeDay` via `wornNightlySkinTempC` (wear-gated mean of `skin_temp_raw@73`, centidegrees ÷100, gated on concurrent worn HR + in-bed session window), then folded against the `skin_temp` baseline in `IntelligenceEngine.recomputeSkinTempDev`. **This is the spine of all three features.**
- **`restingHr`** — nightly resting HR (the luteal-rise input + illness input).
- **`avgHrv`** — nightly RMSSD (the luteal-drop input + illness input).
- **`respRateBpm`** — RSA-derived respiration (illness + secondary cycle input).
- **Personal baselines** for each, via `Baselines.foldHistory` (Winsorized EWMA, cold-start gating, `BaselineState.usable`/`.trusted`). The `skin_temp` deviation config already exists (`VitalBands.skinTempDeviationCfg`, ±°C; the absolute-°C `skin_temp` cfg is in `Baselines.metricCfg`).
- **Journal tags** — `JournalEntry` (`question`, `answeredYes`, `day`) merged across imported WHOOP journal + native `noop-journal` (`Repository.journalEntries`). The starter catalog (`JournalCatalogStore.starterQuestions`) already includes **"Did you drink any alcohol?"**, **"Did you feel stressed?"**, **"Did you feel sick or ill?"**, **"Did you use a sauna?"** — exactly the confounders illness warning must cross-check.
- **Accelerometer / motion** — 3-axis gravity stream (`gravitySamples`) and `StepsEstimateEngine.dayMotionIntensity` already roll it into a per-day motion volume. This is the **rest-activity** input for the circadian cosinor.
- **Existing illness scaffolding** — `AppModel.evaluateIllness` (the current 2-of-4-flags rule), `healthAlert: String?`, `HealthAlertBanner`, `IllnessNotifier` (rate-limited, once-per-day, "not a diagnosis" copy), `BehaviorStore.illnessWatch` toggle. **Heads-Up replaces the body of `evaluateIllness` with an engine call; the surfaces stay.**
- **Stats primitives** — `CorrelationEngine` (Pearson, lagged, day-alignment), `BehaviorInsights` (Welch t-test, Cohen's d, day partitioning by tag). Reused for confounder cross-checks and (later) "what moves your cycle symptoms."

### New (small, on-device only)

- **`CyclePhaseEngine`** — phase classifier + (optional) period-onset estimate from the nightly series. Pure.
- **`CircadianEngine`** — cosinor fit over nightly temp minimum + rest-activity → estimated body-clock phase (temperature nadir time) → light/sleep-timing prescription. Pure.
- **`IllnessSignalEngine`** — multi-signal anomaly score with confounder suppression. Pure. (Replaces the inline `AppModel.evaluateIllness` logic.)
- **One new opaque settings source** for cycle: period-start days the user *optionally* logs (a new journal-style native question or a dedicated `noop-cycle` metric-series source, mirroring `MoodStore.moodDeviceId`). **Logging is optional** — the engine works in a temperature-only "awareness" mode with no manual input.
- **Nightly temp *minimum* time** — a new lightweight field the analytics pass can emit (the timestamp of the lowest worn skin-temp sample in the night), needed for the cosinor. Computed from the same wear-gated samples `wornNightlySkinTempC` already iterates — a few lines, no new BLE.

**No new sensors, no new BLE writes, no firmware work.** Everything is derived from streams already banked.

---

## On-device algorithm (grounded, cite the research approach)

All three are deterministic, DB-free pure functions in the shared engine, scored against the user's **own** rolling baseline — never a population cutoff. Every output carries a confidence tier and is explicitly **APPROXIMATE / awareness-only**.

### 1. Cycle Phases — `CyclePhaseEngine`

**Research basis (publicly documented, branded for legal cover):** the wrist skin-temperature method validated in *PMC11294004* and the broader literature on the **biphasic ovulatory temperature shift** — skin temperature is **~0.3–0.5 °C higher in the luteal phase** than the follicular phase, with a nadir around ovulation, mirrored by a **luteal resting-HR rise** and a **luteal HRV (RMSSD) drop**. NOOP re-derives this independently from the user's own banked signals; it does not reproduce any competitor's model.

**Inputs (per night, last ~60–90 days):** `skinTempDevC`, `restingHr` (vs baseline), `avgHrv` (vs baseline), optionally logged period-start days.

**Method:**
1. Build a **fused luteal index** per night: a weighted sum of the standardized deviations — temp ↑, RHR ↑, HRV ↓ — using `Baselines.deviation` z-scores against each metric's `BaselineState`. (Temp dominant; RHR/HRV corroborate. Weights pinned by test.)
2. **Phase segmentation** without requiring a logged period:
   - **Temperature-only mode (default):** detect the sustained luteal *elevation* (a run of nights with fused index above the personal mean by ≥ k·spread) and the follicular *baseline* run. Classify the current night as **Follicular / Peri-ovulatory / Luteal** from where it sits relative to the most recent elevation onset, plus a coarse cycle-day estimate from the median inter-elevation interval.
   - **Logged-period mode (better):** anchor day-1 to the user's logged period-start; phase = cycle-day bucket, *cross-validated* against the temperature shift so a mistimed log is flagged ("your temperature shift came later than your logged date").
3. **Period-window estimate (optional, clearly probabilistic):** the luteal→follicular temperature *drop* historically precedes menses. Estimate a **window** ("a period is likely in the next few days") from the personal median cycle length — **never a single confident date**, never framed as fertile/safe days.
4. **Honest gating:** needs ≥ ~1.5 personal cycles of nightly data and a `usable` skin-temp baseline. Before that: "Learning your pattern — keep wearing it." Irregular/absent shifts → "No clear pattern yet" (never invent one). Pregnancy, perimenopause, hormonal contraception, PCOS, and shift work all flatten or distort the signal — the engine says so plainly rather than mis-classifying.

**Output:** current phase label + confidence, cycle-day estimate (range, not point), optional next-period window, and the nightly temp curve with shift markers.

### 2. Body Clock — `CircadianEngine`

**Research basis:** the **core-body-temperature minimum (CBTmin)** is the canonical circadian phase marker; CBTmin sits roughly 2–3 h before habitual wake. Wrist skin temperature runs broadly **anti-phase** to core temperature (skin warms as core cools at sleep onset), so the **nightly skin-temperature maximum / the timing of the thermal rhythm** is a usable on-device phase proxy. We combine it with the **rest-activity rhythm** (accelerometer) via **cosinor analysis** (Halberg's single-component cosine fit) — the standard actigraphy method for estimating circadian phase (acrophase) — to estimate the user's body-clock phase and its day-to-day drift.

**Inputs:** the nightly temp-minimum/rise timing (new lightweight field), the per-night thermal curve, and the per-hour motion volume (`gravitySamples` → `StepsEstimateEngine.dayMotionIntensity` per hour bin) over a trailing window.

**Method:**
1. **Cosinor fit** (single 24 h component): least-squares fit of `M + A·cos(2π(t − φ)/24)` to the rest-activity series → **acrophase** (peak-activity clock time) and amplitude; corroborate the phase with the thermal-rhythm timing. Pure linear algebra (regress on `cos`/`sin`, recover amplitude+phase) — fits the existing "transparent published method" house style.
2. **Phase estimate:** report the estimated body-clock phase as a familiar number — an **estimated temperature-minimum clock time** and a chronotype lean (earlier/later than your sleep schedule implies).
3. **Jet-lag / shift advisor:** given a destination time-zone offset (or a new shift pattern the user enters), compute the **phase shift required** and prescribe a **light/sleep-timing plan** using the well-established **phase-response-curve direction rule**: to advance the clock (eastward / earlier shift) → bright light in the morning, dim evenings, earlier sleep, stepped ~1 h/day; to delay (westward / later shift) → bright light in the evening, the reverse. NOOP **does not** prescribe melatonin or any supplement/drug — light + sleep timing + a stepped schedule only.
4. **Daily nudge:** "Your body clock looks ~40 min later than your alarm — get morning light and aim for lights-out by 23:10 to close the gap." Awareness + behaviour, never a guarantee.

**Honest gating:** needs ≥ ~7–10 nights for a stable fit; thin/irregular wear → wide confidence, stated. Shift workers and the chronically irregular get an honest "your rhythm is hard to read right now."

### 3. Heads-Up (illness early-warning) — `IllnessSignalEngine`

**Goal vs the current banner:** today's `AppModel.evaluateIllness` is a blunt 2-of-4 threshold rule (RHR +5 bpm, HRV −20%, skin-temp +0.6 °C, resp +1.5 bpm) with **no confounder handling** — it cries wolf after a night out. The engine keeps the same multi-signal spine but adds **calibrated scoring + false-positive suppression.**

**Research basis:** the multi-parameter pre-symptomatic signature documented across the wearable-illness literature (e.g. the *Stanford/Snyder* resting-HR-elevation work and successor studies) — **resting-HR ↑, skin-temp ↑, HRV ↓, respiration ↑** together, days before symptoms. NOOP re-implements the *pattern*, transparently, against personal baselines.

**Method:**
1. **Per-signal personal anomaly** via `Baselines.deviation` z-scores (recent 1–2 nights vs the trusted baseline ending a few days back, reusing the existing window logic): skin-temp ↑, RHR ↑, HRV ↓, respiration ↑. Each contributes a bounded, signed sub-score in the *illness* direction.
2. **Composite anomaly score** (0–100) instead of a binary count, so the surface can read "mild" vs "strong." Threshold + minimum-signal gates (≥ 2 corroborating signals) preserved to avoid single-noisy-night flags.
3. **False-positive suppression — the differentiating part.** Before raising, cross-check the **journal tags for the same day(s)** (`Repository.journalEntries`):
   - **Alcohol** ("Did you drink any alcohol?") — alcohol elevates RHR + skin temp and crushes HRV exactly like early illness. If tagged → **suppress / downgrade** to "looks like an alcohol night, not necessarily illness."
   - **Stress** ("Did you feel stressed?"), **sauna** ("Did you use a sauna?"), **late/intense workout**, **hot ambient** — each a known temp/HR confounder; downgrade with the named reason.
   - **Travel / new time-zone** — a detected phase jump from `CircadianEngine` (jet lag) explains a temp/RHR shift; cross-feature suppression.
   - **Already sick** ("Did you feel sick or ill?") — if the user already logged illness, switch copy from "early warning" to "rest up — you've logged feeling unwell," no scare.
4. **Explainability:** the surface always shows **why** ("RHR +6, HRV −22%, skin temp +0.7 °C") **and** what was *ruled out* ("no alcohol logged, no travel detected"). This is what earns trust and separates it from a black-box "you might be getting sick."
5. **Honest gating + framing:** needs a `trusted` baseline; below that, silent. Never names a condition. Always "a heads-up to rest," explicitly **not a diagnosis** (reuse the existing `IllnessNotifier` copy: *"On-device estimate (approximate) — not a diagnosis."*).

---

## Architecture & files (engine package + Kotlin twin + UI; what to reuse)

**Pattern (matches Fitness Age / Vitality / Steps):** pure engine in `StrandAnalytics` (serves macOS + iOS), value-for-value Kotlin twin in `android/.../analytics`, unit-tested both sides; orchestration in `IntelligenceEngine` (writes results to the metric-series tall table under the `-noop` computed source); UI per platform.

### New shared Swift engines — `Packages/StrandAnalytics/Sources/StrandAnalytics/`
- `CyclePhaseEngine.swift` — pure. Inputs: nightly `(day, skinDevC, rhrZ, hrvZ)` series + optional logged period days. Output: `CyclePhase` (phase, cycleDayRange, nextPeriodWindow?, confidence, shiftMarkers).
- `CircadianEngine.swift` — pure. Cosinor fit + phase estimate + `JetLagPlan` (per-day light/sleep prescription for a target offset). Reuse `CorrelationEngine`'s normal-CDF/erf helpers for fit confidence if needed.
- `IllnessSignalEngine.swift` — pure. Inputs: recent vs baseline z-scores per signal + same-day tag set + optional circadian-phase-jump flag. Output: `IllnessSignal` (score 0–100, level, firedSignals[], suppressedBy[], copy).

**Reuse, don't re-derive:** `Baselines` (deviation/foldHistory/`BaselineState.usable`), `VitalBands.skinTempDeviationCfg`, `CorrelationEngine`, `BehaviorInsights`, `StepsEstimateEngine.dayMotionIntensity`, `IntelligenceEngine.saturdayKey`/`midnightLocal`/`medianOf`.

### Kotlin twins — `android/app/src/main/java/com/noop/analytics/`
- `CyclePhaseEngine.kt`, `CircadianEngine.kt`, `IllnessSignalEngine.kt` — byte-for-byte logic parity with the Swift, mirroring the existing `FitnessAgeEngine.kt` / `VitalityEngine.kt` pattern. Same `floorMod`/local-day discipline.

### Orchestration (shared shape, per-platform file)
- **Swift:** extend `IntelligenceEngine.analyzeRecent` — after the Vitality/Steps blocks, compute the cycle/circadian results and write the new metric-series keys under the `-noop` computed source (`cycle_phase`, `cycle_day`, `circadian_phase_min`, etc.). Heads-Up replaces the body of `AppModel.evaluateIllness` with an `IllnessSignalEngine.evaluate(...)` call (keeping the `healthAlert`/`IllnessNotifier` plumbing).
- **New field:** add nightly temp-minimum timestamp to `AnalyticsEngine.analyzeDay`'s result + the `DailyMetric` (or a parallel metric-series key) — computed inside the existing `wornNightlySkinTempC` sample loop.
- **Android:** mirror in `IntelligenceEngine.kt` + the Android illness watcher.

### Storage
- Reuse the **metric-series tall table** under the `-noop` computed source (cycle/circadian outputs) and a dedicated `noop-cycle` source for *user-logged* period-start days (mirrors `MoodStore.moodDeviceId` — an import can never clobber it). **No schema change needed** beyond the optional temp-minimum field; everything else is `(deviceId, day, key)` rows.

### UI (per platform)
- macOS SwiftUI screens under `Strand/Screens/`, iOS under `StrandiOS/`, Android Compose under the existing screen package. Reuse `StrandDesign` (`NoopCard`, `StrandPalette`, `StrandFont`), the existing `HealthAlertBanner`, and the v3 Titanium & Gold tokens. **No hardcoded colors.**

---

## Cross-platform plan

Per the cross-platform-parity rule, every feature must reach **all three clients**:

- **macOS + iOS** are covered automatically by the shared `StrandAnalytics` Swift package (engines + orchestration in `IntelligenceEngine`). iOS verified via the `swift test` package suite + the app-build CI (headless XCTest can't run the app target).
- **Android** always needs the **hand-ported Kotlin twin** + Compose UI. Built/verified centrally once (no per-agent gradle), JVM unit-test mirror of every engine.
- **Windows** (port in progress, separate spec) inherits the engines if/when it consumes `StrandAnalytics`; out of scope here but the pure-engine boundary keeps it free.
- **Parity discipline:** identical constants, identical local-day bucketing (`midnightLocal` + `floorMod`), identical gating thresholds, pinned by mirrored test fixtures on both sides. If a wave can't finish all three, back the half-done feature out before release (kept-parity rule).

---

## UX (screens/flows on each platform — honest + skimmable)

**Design language:** v3 Titanium & Gold — navy + gold + titanium, frosted `NoopCard`s, no greens. Every screen leads with a calm headline number/label and a one-line "why," with detail on tap. ARIA/labels on all platforms; `loading="lazy"` n/a (native). All copy avoids medical verbs.

### Cycle Phases
- **Today card (opt-in surface):** "Phase: Luteal · ~day 22" with a small thermal sparkline and a confidence chip ("Solid" / "Building" / "Learning your pattern"). Tap → detail.
- **Detail screen:** the nightly skin-temp deviation curve over the last ~90 days with shift markers; the fused luteal index; phase bands; optional "Log period start" button (one tap, stored to `noop-cycle`); an honest **next-period *window*** ("likely in the next 3–6 days," never a hard date). A persistent, prominent privacy line: **"This stays on your device. It is never uploaded, never synced, never shared."**
- **Empty/learning state:** "NOOP is learning your pattern from your nightly temperature — keep wearing it overnight. No data leaves your wrist."
- **Settings:** a single opt-in toggle (default OFF), with the privacy promise restated. Disabling **deletes** the logged period data on request.

### Body Clock
- **Card:** "Body clock: ~25 min later than your schedule" + a chronotype lean; tap for the plan.
- **Detail:** the cosinor curve (activity + thermal), estimated temperature-minimum time, and a **jet-lag planner**: pick a destination (offset) or enter a shift pattern → a day-by-day **light + sleep-timing** card stack ("Day 1: morning light 07:00–08:00, lights-out 22:45"). No supplements, ever.
- **Honest band:** wide-confidence states say so; irregular schedules get "your rhythm is hard to read right now."

### Heads-Up (illness)
- **Surface = the existing `HealthAlertBanner`** (frosted amber `NoopCard`) + the `IllnessNotifier` system notification, unchanged plumbing. New body:
  - **Raised:** "Heads-up — your body looks strained. RHR +6, HRV −22%, skin temp +0.7 °C. No alcohol or travel logged. Consider taking it easy." + "On-device estimate — not a diagnosis."
  - **Suppressed/downgraded:** "Some signals are up, but you logged a few drinks — likely that, not illness." (Quietly informative, not alarming.)
  - **Already-sick:** "Rest up — you logged feeling unwell. Your numbers agree."
- **Settings:** the existing `BehaviorStore.illnessWatch` toggle (default OFF), now with a one-line note that it cross-checks your journal tags to avoid false alarms.

---

## Non-clinical / legal framing (wellness-only — NOT medical, NOT diagnostic)

This is the load-bearing section. Reproductive-health + illness signals are the highest-sensitivity health category; NOOP is a **wellness** product, not a medical device, and every surface must read that way.

- **Cycle Phases is awareness, NOT contraception and NOT a medical service.** Hard rules: never frame as fertility/contraception ("fertile window," "safe days," "ovulation prediction for conception/avoidance" — all banned). Never a guaranteed period date — only a probabilistic *window*. Never "diagnose" PCOS, endometriosis, pregnancy, menopause, or any condition; when the signal is flat/irregular, say "no clear pattern," not a verdict. A standing in-app line: *"For awareness only. Not a medical device, not contraception, not a substitute for professional care."*
- **Heads-Up is "a heads-up to rest," NOT a diagnosis.** Never names an illness, infection, COVID, fever, or condition. Reuse the shipped copy: *"On-device estimate (approximate) — not a diagnosis."* Always "consider taking it easy" / "rest up," never "you are sick" or "see a doctor for X."
- **Body Clock is behavioural awareness.** Light + sleep timing only. **No melatonin, no supplements, no drugs.** "Consider," "aim for," "try" — never "you must."
- **Privacy as the headline, not the fine print.** Because there is no cloud, no account, no telemetry, **this data is physically incapable of leaving the device.** State it on every sensitive surface. This is both the ethical stance and the single biggest competitive wedge against Oura/Apple/Natural Cycles for cycle data specifically — the post-2022 reproductive-data-privacy concern is real and NOOP is the clean answer.
- **Anonymous-project rules hold.** No AI/LLM mentioned anywhere in shipped copy (the only legitimate AI mention remains the opt-in bring-your-own-key AI Coach). USD, never GBP, in any pricing/comparison copy. Methods cited as published science (PMC11294004, cosinor/Halberg, PRC light rules, Stanford illness-signature) — branded, transparent, our own re-derivation, never "AI."
- **Reuse the existing `DISCLAIMER.md` / `TERMS.md` jurisdiction-neutral language.** Add a short cycle/illness wellness-scope clause; keep it neutral (no UK/governing-law leak per the TERMS precedent).
- **Default OFF, opt-in per feature** (manual-first philosophy). Each is a toggle the user turns on, with the privacy promise at the point of opt-in.

---

## Test plan

Mirrored Swift (`StrandAnalyticsTests`) + Kotlin (`androidTest`/JVM) suites, deterministic fixtures, parity-pinned. Follows the existing `SkinTempAnalyticsTests` / `FitnessAgeEngineTest` patterns.

**CyclePhaseEngine**
- Synthetic biphasic series (luteal +0.4 °C elevation, RHR +3, HRV −15%) → correct Follicular/Peri-ovulatory/Luteal classification + plausible cycle-day range.
- Logged-period anchor agrees with the detected shift; a deliberately-mistimed log is flagged.
- Flat/irregular series → "no clear pattern," **never** a fabricated phase.
- < 1.5 cycles of data → "learning"; `usable`-baseline gate honored.
- Next-period output is a *window*, never a single date; pinned wording (no fertility language anywhere — assert the banned strings are absent).

**CircadianEngine**
- Cosinor recovers a known injected acrophase/amplitude within tolerance (pure-math determinism).
- Eastward target → morning-light/advance plan; westward → evening-light/delay; assert **no supplement strings** ever appear.
- Thin/irregular data → wide-confidence state.

**IllnessSignalEngine**
- Classic 3-signal illness pattern (no tags) → raised, score in band, `firedSignals` correct.
- **Same pattern + alcohol tag → suppressed/downgraded** (the core false-positive test).
- Stress / sauna / travel-phase-jump → each downgrades with the named reason.
- Already-sick tag → "rest up" copy, not "early warning."
- Single noisy night / < trusted baseline → silent.
- Copy asserts: contains "not a diagnosis," never names a condition.

**Cross-platform parity:** identical fixtures → identical engine outputs Swift vs Kotlin (the established parity-test approach). Local-day bucketing parity (`midnightLocal`/`floorMod`).

**Privacy assertions:** a test that the cycle/illness engines are pure (no I/O) and that the new sources are written only to local `-noop`/`noop-cycle` ids — no network reference anywhere in the new files.

---

## Phasing (MVP vs later)

**MVP (ship first, in this order — Heads-Up is the cheapest win):**
1. **Heads-Up** — replace `AppModel.evaluateIllness` body with `IllnessSignalEngine` + journal-tag suppression. Reuses every existing surface; highest value-per-line; immediately fixes the "cries wolf after a night out" complaint. Kotlin twin.
2. **Cycle Phases (temperature-only awareness mode)** — classification + thermal-curve detail + privacy framing, **no logged period required**. The headline privacy/free wedge vs Oura.

**Later:**
3. **Cycle logged-period mode + next-period window** — opt-in period logging, cross-validation, probabilistic window.
4. **Body Clock** — cosinor phase estimate + jet-lag/shift planner (needs the new nightly temp-minimum field + the per-hour motion binning; most new math).
5. **Cross-feature fusion polish** — circadian phase-jump feeding Heads-Up suppression; "what moves your cycle symptoms" via `BehaviorInsights`; weekly digest line.

---

## Open questions

1. **Period-start logging surface** — new native journal question ("Period started today?") vs a dedicated `noop-cycle` metric-series source (like `MoodStore`)? The dedicated source is cleaner for privacy + deletion but adds a store path. **Lean: dedicated source.**
2. **Default visibility of Cycle Phases** — only surface the card if the user has opted in *and* `profile.sex == "female"`? Or offer it to everyone who opts in (some users track for non-female reasons; avoid gatekeeping by a single field)? **Lean: opt-in to all, no sex gate, since the engine self-gates on signal.**
3. **Heads-Up severity surfacing** — keep the single binary banner, or add a low-key "mild signals" state below the threshold? Risk of re-introducing noise. **Lean: keep binary banner for raised; "mild" only in a detail view, not a notification.**
4. **Cosinor input** — rest-activity (accelerometer) as the primary phase signal with thermal as corroboration, or thermal-primary? Skin temp is noisier as a phase marker but it's the pillar's signal. **Lean: rest-activity primary, thermal corroborating; revisit with real captures.**
5. **Wear-coverage minimum** for a trustworthy nightly temp minimum (the cosinor input) — what fraction of the night must be worn? Reuse the `wornNightlySkinTempC` gate or tighten it.
6. **Jet-lag input** — auto-detect time-zone change from the device clock vs require the user to enter the trip? Auto-detect is magical but can misfire; manual is honest. **Lean: manual entry MVP, auto-detect later.**
7. **Confidence taxonomy** — reuse the Charge/Effort/Rest `ScoreConfidence` tiers (Solid/Building/Calibrating) verbatim for consistency, or cycle-specific wording? **Lean: reuse, for one mental model.**
8. **Naming** — "Cycle Phases" / "Body Clock" / "Heads-Up" vs alternatives. the maintainer's call; "Heads-Up" deliberately avoids "illness."
