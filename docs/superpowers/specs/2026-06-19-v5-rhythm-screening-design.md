# NOOP v5 — "Rhythm" experimental irregular-rhythm screening — design

**Pillar:** Rhythm screening (FRONTIER — ships clearly-EXPERIMENTAL + opt-in, or is held; see §11).
**Status:** Design only. NOT approved. NOT built. Highest-liability feature NOOP has ever scoped.
**Date:** 2026-06-19.
**Engine:** new `RhythmScreener` in `Packages/StrandAnalytics` + Kotlin twin `RhythmScreener.kt`.
**Reuses:** `HRVAnalyzer` (ectopic rejection), the R-R stream (`RRInterval`), raw PPG (`SpO2Sample` red/IR),
accelerometer (`GravitySample`), `PpgHr` autocorrelation, `ScoreConfidence` pattern.

> **One-line honest summary of what this is:** a wellness heads-up that says *"your beat-to-beat
> rhythm looked irregular during this quiet window — that is often nothing, but if it keeps happening
> you may want to mention it to a clinician."* It is **not** an ECG, **not** AFib detection, **not** a
> diagnosis, **not** a medical device. It cannot tell you *why* a rhythm looked irregular.

---

## 1. Goal & differentiation (why only NOOP)

WHOOP gates its on-demand **ECG / "Irregular Heart Rhythm Notifications" (IHRN)** to the **MG**
hardware on the top **$359/yr** membership tier. Apple/Samsung gate AFib features to specific watches
behind FDA/CE clearance. Oura's "Symptom Radar" is illness-trend, not rhythm. So a person wearing a
**WHOOP 4.0** — the most common strap in the wild — has **no path at all** to even a rough heads-up
that their pulse looked irregular last night.

NOOP already has, on **every** strap (4.0 and 5.0/MG), the one signal these features are ultimately
built on top of: **beat-to-beat timing.** From the strap's own R-R intervals (and, on 5.0 stretches
that only stream optical PPG, from the raw red/IR waveform NOOP already decodes), NOOP can compute the
**irregularity statistics** that an irregular-rhythm screen is made of — entirely **on-device, offline,
free, no subscription.**

The differentiation is structural, not marketing:

- **Reasons from raw beat timing**, not a cloud-scored summary. Competitors that *could* do this choose
  not to, or paywall it; NOOP already holds the R-R stream and the PPG waveform locally.
- **Works on a 4.0**, where every cleared/branded feature refuses to.
- **On-device + offline.** No sample of your heartbeat ever leaves the device. (This is also the
  *responsible* posture for a high-sensitivity signal.)
- **Honest about being a screen, not a test.** The entire value is "consider getting this checked,"
  delivered conservatively — which is exactly the framing a non-cleared wellness app is *allowed* to
  give. We are not competing with an ECG; we are competing with *nothing*, which is what a 4.0 owner
  has today.

**What it is NOT, and we say so loudly:** not a diagnosis, not ECG-equivalent, not a substitute for
care, and structurally prone to false positives (motion, ectopy, a wandering optical contact all look
"irregular"). The honest pitch is a nudge to a human clinician, never a verdict.

---

## 2. Data & signals used (already available vs new)

### Already available (no new decoding)
| Signal | Source in repo | Notes |
|---|---|---|
| **R-R intervals** | `RRInterval(ts, rrMs)` — `Streams.rr`, from `REALTIME_DATA` (type 40) **and** the standard `0x2A37` HR characteristic (`StandardHeartRate.parse` returns `rr: [Int]`, 1/1024 s → ms). | The core input. **Crucially present on WHOOP 4.0** via 0x2A37. Stored in `rrInterval` table, read by `Reads.rrIntervals(deviceId:from:to:limit:)`. |
| **Live R-R** | `LiveState.rrRecent` (bounded rolling buffer) + `setRRIntervals(_:)`. The `keepRealtimeForData` / `noopContinuousHrv` toggle (`PuffinExperiment.keepRealtimeForDataKey`) already keeps the realtime R-R feed armed for HRV. | Lets a *live* "check my rhythm now" spot-check reuse the same tap the breathing trainer uses. |
| **Raw PPG (red/IR)** | `SpO2Sample(ts, red, ir, unit:"raw_adc")` — `Streams.spo2`, type-47 historical. | Motion-robust fusion input + an *independent* beat-timing source to cross-check R-R (see §3.4). |
| **PPG autocorrelation** | `PpgHr.estimate(...)` / `derivePpgHr(...)` — detrend, de-artifact comb, normalised-ACF peak + confidence. | Reuse the windowed-ACF machinery to extract beat instants from PPG for the fusion path. |
| **Accelerometer** | `GravitySample(x,y,z,g)` — `Streams.gravity`. | Motion gate: irregularity during movement is **discarded**, not screened. The single biggest false-positive killer. |
| **Ectopic rejection** | `HRVAnalyzer.rejectEctopic` (Malik 20% local-median), `rangeFilter` [300,2000] ms. | We **invert** part of this: HRV throws ectopics away; Rhythm *counts* them — but reuses the exact same range filter and the median helper. |
| **Confidence tiering** | `ScoreConfidence` (calibrating/building/solid) pattern. | A near-identical `RhythmConfidence` rides every screen result. |

### New (small, additive — no protocol changes)
- A **`RhythmScreener`** engine (Swift + Kotlin twin) computing the irregularity statistics in §3.
- A **`RhythmWindowResult`** row type and an opt-in store table `rhythmWindow` (mirrors existing
  `MetricSeriesStore` style) so the (very sparse) flagged windows can be reviewed. **Default: nothing
  is computed or stored until the user opts in and passes the consent gate (§9).**
- One settings flag (`noopRhythmScreening`, default **OFF**), gated behind a one-time consent screen.

No firmware writes, no new BLE commands, no cloud. Everything rides signals NOOP already decodes.

---

## 3. On-device algorithm (grounded)

> **Design stance:** prefer **conservative, well-cited, fully-deterministic** statistics over a black
> box. Every threshold is a published heuristic we can name in the disclaimer, exactly as the
> Charge/Effort/Rest spec keeps "transparent published science … the honesty differentiator and the
> legal cover." We screen for **irregularity**, and we explicitly **decline to name a condition.**

### 3.1 Eligibility gate (when we even look)
A window is screened **only** when it is a clean resting window — this is the single most important
guard against false positives:
- **Rest only.** Motion gate from `GravitySample`: the per-window accelerometer variance must be below
  a "still" threshold (reuse the sedentary/still logic family). Any movement → window **skipped**, not
  flagged. (Most published optical-irregularity screens are explicitly **rest/sleep-only** for this
  reason.)
- **Signal quality.** Require ≥ `minBeats` (start at 60, well above HRV's 20) clean R-R intervals in
  the window after `HRVAnalyzer.rangeFilter`, and, on the PPG fusion path, a mean ACF confidence above
  `PpgHr.minConfidence`. Sparse/garbage window → "couldn't read clearly," never a flag.
- **Plausible rate.** Mean HR within a resting band (e.g. 40–110 bpm). Outside → skip (likely artifact
  or activity the motion gate missed).

### 3.2 The core irregularity statistics (R-R path — works on 4.0)
Over a clean resting window of N successive NN intervals (range-filtered, but **not** ectopic-stripped —
we need the ectopy), compute, all from published HRV/arrhythmia-screening literature:

1. **pNN-style scatter (Poincaré).** Build the Poincaré plot of (NN[i], NN[i+1]) and compute **SD1**
   and **SD2** (the standard rotated SDs of the cloud) and the **SD1/SD2 ratio.** A normal sinus rhythm
   gives a tight, elongated comet; AFib-like irregularity gives a **diffuse, round** cloud (SD1/SD2 → 1
   and SD1 large). SD1 = `RMSSD/√2` (so we get it nearly free from `HRVAnalyzer.rmssdRaw`), SD2 derived
   from SDNN and SD1. — *Poincaré / Lorenz-plot R-R analysis is a long-standing arrhythmia-screening
   approach (e.g. the Lorenz-plot density methods used in implantable-monitor AF detection).*
2. **Irregularity / entropy.** Two cheap, deterministic measures:
   - **Coefficient of sample entropy / "irregularity index"** approximated by the **normalised RMSSD**
     (RMSSD / meanNN) — high sustained values at rest are the classic optical AFib-screen signal.
   - **Turning-point / sign-change rate** of successive ΔNN — random beat-to-beat direction flips are
     a hallmark of disorganised rhythm vs the smooth respiratory modulation of sinus.
3. **Ectopic burden.** Run `HRVAnalyzer.rejectEctopic` *as a counter*: the **fraction of beats it would
   drop** (`(nClean − rejected)/nInput`) is an **ectopic-beat rate**. A run of isolated drops = possible
   ectopy ("skipped/extra beats"); a *sustained high* drop fraction with high SD1/SD2 = the irregular
   pattern we flag. This neatly **reuses the existing filter** for the opposite purpose.

A window is **provisionally irregular** when (conservative AND of conditions, tuned on fixtures):
`SD1/SD2 ≥ τ_ratio` **and** normalised-RMSSD `≥ τ_nrmssd` **and** turning-point rate `≥ τ_tp`. Single
isolated ectopics (low overall scatter, a few drops) are reported separately as **"occasional extra/skipped
beats"** — explicitly framed as *usually benign and extremely common.*

### 3.3 Temporal persistence (the false-positive killer)
**No single window ever produces a notification.** A "heads-up" only appears when **multiple
non-contiguous windows over a sustained span** (e.g. ≥ K irregular windows across ≥ M minutes within one
night, K/M tuned high) all pass §3.2. Brief blips are logged but never surfaced. This mirrors how
cleared screens require *persistence/burden*, and is the main lever we turn toward "almost never cries
wolf."

### 3.4 PPG + accelerometer fusion (motion-robustness — the frontier path)
On 5.0 stretches where R-R is sparse but raw red/IR PPG is dense, and as an **independent confirmation**
channel on 4.0:
- Extract **inter-beat intervals from PPG** via the existing `PpgHr` ACF/peak machinery (beat instants,
  not just a rate), then run the **same §3.2 statistics** on the PPG-derived IBI series.
- **Require agreement.** A flag is only raised if the R-R path *and* the PPG path agree (or, on a
  PPG-only window, if PPG irregularity persists AND the motion gate is firmly "still"). Disagreement →
  no flag (it's probably motion/contact noise).
- This two-signal-must-agree design is the spirit of motion-robust optical rhythm screening (the
  RhythmiNet line of work, arXiv 2511.00949, fuses PPG + accelerometer so motion doesn't masquerade as
  arrhythmia). **We deliberately do NOT ship a neural net in MVP** — we ship the deterministic
  agreement gate, which is auditable, testable, and citable. A learned model is explicitly a *later*,
  separately-reviewed phase (§10), if ever.

### 3.5 What we never do
- Never name a condition ("AFib", "PVC", "arrhythmia") as a **conclusion** in shipped copy. We may say
  *"irregular rhythm"* descriptively and reference that "irregular rhythms have many causes, including
  benign ones."
- Never produce a number that looks like a clinical metric (no "AFib probability 73%"). The output is a
  **categorical, conservative** state: *Looked regular* / *Some irregular beats* / *Looked irregular —
  consider a clinician*, plus a plain-language confidence.
- Never alarm. No red, no urgency styling, no push at 3am. A calm, dismissible card the next morning.

---

## 4. Architecture & files (engine + Kotlin twin + UI)

### Shared Swift engine (serves mac + iOS)
`Packages/StrandAnalytics/Sources/StrandAnalytics/RhythmScreener.swift` — **pure, Foundation-only,
no UI, no I/O.** Public surface (sketch):

```
public enum RhythmScreener {
    public struct WindowInput {            // one resting window, already assembled by the caller
        let rr: [RRInterval]
        let ppgIBIms: [Double]?            // optional PPG-derived inter-beat intervals
        let motionStill: Bool              // from GravitySample variance gate
        let meanHR: Double
    }
    public struct WindowResult: Equatable, Sendable, Codable {
        let state: RhythmState             // .regular / .occasionalEctopy / .irregular / .unreadable
        let sd1: Double?; let sd2: Double?; let sd1sd2: Double?
        let normRmssd: Double?; let turningPointRate: Double?; let ectopicFraction: Double?
        let nBeats: Int
        let confidence: RhythmConfidence   // mirrors ScoreConfidence
        let agreedAcrossSources: Bool
    }
    public static func screenWindow(_ input: WindowInput) -> WindowResult
    public static func summarizeNight(_ windows: [WindowResult]) -> NightRhythmSummary // §3.3 persistence
}
public enum RhythmState: String, Codable, Sendable { case regular, occasionalEctopy, irregular, unreadable }
public enum RhythmConfidence: String, Codable, Sendable { case calibrating, building, solid }
```

- **Reuses** `HRVAnalyzer.rangeFilter`, `HRVAnalyzer.rejectEctopic` (as the ectopic *counter*),
  `HRVAnalyzer.rmssdRaw`/`sdnnRaw`/`median`, and `PpgHr.estimate` for PPG IBI extraction. No
  re-implementation of those.
- All thresholds are named `static let` constants at the top (`tauRatio`, `tauNRmssd`, `tauTP`,
  `windowMinBeats`, `nightMinIrregularWindows`, …) so they are testable and tunable in one place.

### Storage (opt-in, sparse)
- New `rhythmWindow` table via `WhoopStore` migration (id, deviceId, windowStart, windowEnd, state,
  stats blob, confidence). Follows `MetricSeriesStore` conventions. **Only written when the feature is
  ON.** A short retention/prune policy (these are tiny + rare).

### Orchestration
- A `RhythmService` (app layer, not the package) assembles resting windows from `Reads.rrIntervals`,
  `spo2`, and `gravity` over a completed sleep window (post-offload, same hook as nightly scoring), runs
  the engine, persists results, and decides whether `summarizeNight` warrants a single morning card.
- Live "check now" path: a screen reads `LiveState.rrRecent` (requires `keepRealtimeForData`/continuous
  R-R armed) and runs `screenWindow` on a ~60–90 s captured window.

### Kotlin twin (value-for-value)
`android/app/src/main/java/com/noop/analytics/RhythmScreener.kt` — **faithful byte-for-byte-behaviour
port**, exactly as `HrvAnalyzer.kt` mirrors `HRVAnalyzer.swift` ("verified on macOS"). Reuses the
existing `com.noop.analytics.HrvAnalyzer` (rangeFilter/rejectEctopic/median) and the Android PPG
estimator. Same constants, same `RhythmState`/`RhythmConfidence` enums, same results on shared fixtures.

### UI (per platform — NOT in the packages)
- macOS/iOS SwiftUI screen + morning card (`StrandDesign` tokens).
- Android Compose screen + card.

---

## 5. Cross-platform plan

Follows the established NOOP parity discipline (shared Swift package auto-covers mac+iOS; Android always
needs a hand-port; verify iOS centrally):

1. **Swift engine + tests land first**, green on macOS via the `StrandAnalytics` package test target
   (headless XCTest can't run the app, but the package suite + Android JVM mirror can).
2. **Kotlin twin + JVM tests** ported next, sharing the **same synthetic fixtures** (§8) so both
   platforms produce identical `RhythmState`/stats on the same input — this is the parity gate.
3. **Fixtures live once**, in `Fixtures/`, as plain JSON R-R / IBI series + expected results, consumed
   by both test suites (mirrors how golden JSON is shared today).
4. UI is per-platform and ships behind the same OFF-by-default flag + consent gate on all three.
5. Central build-verify all three before any release; if the Kotlin twin lags, the feature stays OFF on
   Android rather than shipping divergent behaviour.

---

## 6. UX (screens / flows, honest + skimmable)

**Entry point.** Settings → "Labs / Experimental" → **"Rhythm screening (experimental)"**, OFF by
default. Tapping it opens the **consent gate** (§9) *before* anything computes.

**The morning card (only when persistence §3.3 trips).** Calm, neutral (titanium/navy, **never red**):
> **Heads-up: your rhythm looked irregular last night**
> During a few quiet periods, your beat-to-beat timing looked more irregular than usual. This is
> **not a diagnosis** and is **often nothing** — but if you see this often, or feel unwell, it's worth
> mentioning to a clinician. *NOOP is a wellness app, not a medical device, and cannot detect any heart
> condition.* [What this means] [Dismiss]

**Detail screen.**
- Plain-language state: *Looked regular* / *Some occasional extra or skipped beats* / *Looked
  irregular in places*.
- A **Poincaré plot** of the night's R-R (genuinely informative + honest — you can *see* the scatter),
  with one line of "tight comet = regular, diffuse cloud = irregular" explanation.
- Confidence line ("Building — only one short clean window") so a thin night reads truthfully.
- A permanent, non-dismissible disclaimer block (§9 wording).
- **"Share with my clinician"**: exports a local PDF/CSV of the window timings + plot the user can hand
  to a doctor — framed as *"raw timing data for a professional to interpret,"* never as a report.

**Live "Check my rhythm now."**
- A ~60–90 s capture using the breathing-trainer's R-R tap. Big honest caveats: "hold still," "this is a
  rough wellness check, not an ECG."
- Result is the same categorical state + the same disclaimer. A single live check **never** escalates to
  an alarm; at most it suggests running it again at rest or seeing a clinician if it persists.

**Tone rules:** no urgency, no red, no "ALERT," no push notifications for rhythm. Everything is
next-morning, dismissible, and worded as *"consider mentioning to a clinician,"* never *"you have…"* or
*"you should seek care immediately"* (which would itself be an implied medical claim/triage we are not
qualified or cleared to make).

---

## 7. Non-clinical / legal framing (the load-bearing section)

This is the **highest-liability feature in NOOP** and the framing is not decoration — it is the feature's
license to exist as a wellness app. NOOP already states in `DISCLAIMER.md §5` that all outputs are
"approximations … not clinically validated … not a medical device … not medical advice. Do not use them
to diagnose…". Rhythm screening needs its **own dedicated sub-section** in that same register.

### 7.1 New `DISCLAIMER.md §5.4` (proposed exact wording)
> **5.4 Rhythm screening — experimental wellness heads-up, NOT heart-condition detection.**
> The optional **Rhythm screening** feature looks at the *regularity of your beat-to-beat timing* during
> quiet, resting periods and may show an **experimental** heads-up if that timing looked unusually
> irregular. It is **not** an electrocardiogram (ECG/EKG), **not** atrial-fibrillation or arrhythmia
> detection, **not** a diagnosis, **not** a medical device, and **not** a substitute for professional
> care. It **cannot detect, rule out, or monitor any heart condition.** Irregular beat-to-beat timing
> has many causes, including completely benign ones (normal variation, the occasional extra or skipped
> beat that most healthy people have, movement, breathing, or simply an imperfect optical reading). This
> feature is **experimental, conservative, and expected to produce false positives and false negatives**;
> a "regular" result is **not** reassurance that your heart is healthy, and an "irregular" result is
> **not** evidence that anything is wrong. **Never** start, stop, or change any treatment based on it.
> **If you feel faint, have chest pain, shortness of breath, palpitations that worry you, or any
> symptom that concerns you — contact a qualified professional or your local emergency service straight
> away; do not rely on NOOP.** All processing happens on your own device; no heartbeat data is sent
> anywhere.

### 7.2 Copy rules enforced everywhere (lint-able)
- Banned as **conclusions** in shipped copy: "AFib", "atrial fibrillation", "arrhythmia", "diagnose",
  "ECG/EKG result", "detected a heart condition", any "%/probability of <condition>", "you have",
  "you should seek emergency care" as an app-issued triage.
- Required near every result: "experimental," "not a diagnosis / not a medical device," "consider
  mentioning to a clinician," and the emergency-services line.
- Allowed: descriptive *"your rhythm looked irregular"* / *"occasional extra or skipped beats"* with the
  benign-causes caveat attached.
- Mirror the §5.1 Mind-feature pattern (NOOP already ships a non-clinical mental-health sub-section with
  a crisis line — proven house style for exactly this).

### 7.3 Other obligations
- USD throughout (the differentiation copy: WHOOP's ECG sits behind a **$359/yr** tier — never GBP).
- Anonymity preserved: no AI/LLM mentioned anywhere in shipped copy (the deterministic engine makes this
  easy — there's literally no model to hide). The only sanctioned AI mention remains the opt-in
  bring-your-own-key AI Coach, which must **not** be wired to interpret rhythm results.
- Honest-about-limits banner stays even in the "looked regular" state.

---

## 8. Test plan

Shared synthetic fixtures in `Fixtures/`, consumed by **both** Swift (`RhythmScreenerTests.swift`) and
Kotlin (`RhythmScreenerTest.kt`) so results are identical cross-platform.

**Synthetic generators (deterministic, seeded):**
- **Normal sinus** R-R: ~60 bpm mean with realistic respiratory sinus arrhythmia → expect `.regular`,
  tight Poincaré (low SD1/SD2), **no** night-level flag.
- **AFib-like** irregular R-R: high-variance, low-autocorrelation series (round Poincaré cloud) → expect
  `.irregular` at window level AND a night summary flag when persistence is met.
- **Isolated ectopy**: mostly sinus with sparse single short-long ("skipped beat") couplets → expect
  `.occasionalEctopy`, **not** `.irregular`, and **no** scary night flag.
- **Motion-contaminated**: irregular-looking R-R with `motionStill = false` → expect `.unreadable`
  /skipped (motion gate must win — the key false-positive test).
- **Sparse/garbage**: < `windowMinBeats` clean → `.unreadable` with `.calibrating` confidence.
- **PPG-disagreement**: R-R path says irregular but PPG IBI path says regular → **no flag** (agreement
  gate).

**Property/threshold tests:** SD1 ≈ RMSSD/√2 identity; ectopic-fraction reuses `rejectEctopic` correctly;
night persistence requires K-of-M and ignores single blips; thresholds documented and pinned.

**Parity test:** the same fixture JSON yields identical `RhythmState` + rounded stats on Swift and
Kotlin (the cross-platform gate; matches the existing HrvAnalyzer parity practice).

**Negative/safety tests:** assert no shipped copy string contains banned conclusion terms (a simple unit
test over the localized strings catalog), and that no notification path can be triggered from a single
window.

**No real patient data, ever** — synthetic only; the repo never ingests clinical recordings.

---

## 9. The consent gate (design carefully — this is the riskiest UI)

Model it on the existing **`TermsGateView`** clickwrap (un-pre-checked box, must tick + tap to proceed,
acceptance recorded locally) — but **feature-specific** and shown the **first time** the user enables
Rhythm screening, again if the wording materially changes:

- Title: **"Before you turn on Rhythm screening"**
- Bullets the user must read (each its own line, like `Terms.points`):
  1. *This is experimental and not a medical device.* It is **not** an ECG and **cannot** diagnose,
     detect, or rule out any heart condition.
  2. *It will sometimes be wrong* — both false alarms and misses are expected. Treat every result as a
     rough heads-up, never a verdict.
  3. *Irregular timing is often benign.* Many healthy people have occasional extra or skipped beats.
  4. *It is not a substitute for a clinician.* If you feel unwell or are worried, contact a qualified
     professional; in an emergency, your local emergency service.
  5. *Everything stays on your device.* No heartbeat data leaves it.
- A single **un-pre-checked** checkbox: *"I understand this is an experimental wellness feature, not a
  medical device or diagnosis."* — Accept disabled until ticked.
- Record acceptance locally (the on-device "consent record" pattern `TermsGateView` already uses), with a
  version so material changes re-prompt.
- The feature **stays OFF** if they back out.

---

## 10. Phasing

**MVP (if shipped at all — see §11):**
- R-R-path window screening (§3.2) + motion gate (§3.1) + night persistence (§3.3).
- Categorical states, Poincaré plot, morning card, consent gate, `DISCLAIMER.md §5.4`.
- Engine + Kotlin twin + shared fixtures + parity tests.
- Deterministic only. No PPG fusion, no live "check now."

**Phase 2 (separate review):**
- PPG-derived IBI + the cross-source **agreement** gate (§3.4) for motion-robustness and an independent
  confirmation channel (biggest false-positive reduction).
- Live "check my rhythm now."
- "Share with clinician" export.

**Phase 3 (research, may never ship):**
- A learned motion-robust model in the RhythmiNet spirit (arXiv 2511.00949) — only if it can run
  on-device, be validated against open datasets, and survive its own legal review. Held by default.

Each phase ships OFF-by-default behind the consent gate; nothing auto-enables.

---

## 11. Ship in v5, or hold? (recommendation)

**Recommendation: HOLD the *notification/screening verdict* for v5; ship at most a clearly-labelled
"Beat-to-beat regularity (experimental)" *visualization* — the Poincaré plot + descriptive stats with
NO "consider seeing a clinician" call-to-action — and decide on the screening heads-up later.**

Reasoning, honestly:
- The **engine, twin, tests, and fixtures are low-risk and high-value** to build now — they're just math
  over data we already have, and they make the eventual decision concrete and reviewable.
- The **liability lives entirely in the *output framing*** — the moment the app tells a user "your
  rhythm looked irregular, consider a clinician," it is brushing against the line that separates wellness
  from a medical claim, even with perfect disclaimers. That is a deliberate, eyes-open decision for the maintainer
  to make, not a default-on feature.
- A **regularity *visualization*** (here is your Poincaré scatter, here is what a tight vs diffuse cloud
  looks like) is defensibly wellness/education, mirrors the existing transparent-science posture, and
  carries far less risk — while still being something **no competitor gives a 4.0 owner.**
- If/when the screening heads-up does ship, it should ship **only** with the §9 consent gate, §7.4
  wording, conservative thresholds tuned on fixtures, the persistence gate, and ideally the §3.4
  agreement gate already in place (i.e. effectively Phase 2, not MVP).

So: **build the engine + twin + tests + the honest visualization in v5; gate the "consider a clinician"
screening verdict behind an explicit the maintainer go/no-go and the full consent machinery.**

---

## 12. Open questions

1. **Ship the screening verdict in v5 at all, or only the visualization?** (§11 — the maintainer's call; this is
   the central decision.)
2. **Threshold tuning without clinical data.** We can only tune τ on *synthetic* fixtures and self-tracked
   normal data — we have no labelled AFib recordings and won't acquire any. Is synthetic-only tuning an
   acceptable basis even for an explicitly experimental feature, and how conservative do we set defaults?
3. **0x2A37 R-R fidelity on 4.0.** How clean/dense are the strap's R-R intervals at rest in practice
   (vs the PPG-derived path)? Needs a real overnight R-R capture to confirm the 4.0 headline is real and
   not noise-dominated.
4. **PPG IBI accuracy.** `PpgHr` currently yields a per-second *rate*, not beat *instants*; extracting
   trustworthy inter-beat intervals (peak picking) from the 24 Hz buffer is non-trivial and may not be
   reliable enough for §3.4 — does the fusion path survive contact?
5. **Jurisdictional reach of "consider seeing a clinician."** Even disclaimed, does that phrasing risk
   being read as a medical-device function in any market NOOP is distributed in? Worth a conservative
   legal sanity check before the verdict (not the visualization) ships.
6. **Naming.** "Rhythm" vs "Beat regularity" vs "Pulse steadiness" — pick a name that reads clearly
   *wellness/experimental* and avoids implying a cardiac diagnostic.
7. **Confidence surfacing.** Should a low-confidence "looked irregular" be suppressed entirely (shown
   only at solid confidence) to further cut false alarms?
