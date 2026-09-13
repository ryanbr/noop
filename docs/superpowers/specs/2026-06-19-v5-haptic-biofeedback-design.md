# NOOP v5 — Haptic Biofeedback ("the strap that breathes you down")

**Pillar:** Closed-loop haptic biofeedback. NOOP both *measures* the autonomic response (live
beat-to-beat R-R → RMSSD / HF-RSA) and *acts on the body* through the strap's haptic motor — so it can
pace, entrain, and nudge the nervous system, then show the user a **measured** outcome. No competitor
ships this loop: their straps/rings either don't buzz, don't expose raw R-R locally, or don't compute
on-device.

**Status:** DESIGN ONLY (not approved, not built). Wellness/relaxation feature — explicitly **not**
medical, diagnostic, or a treatment. See *Non-clinical / legal framing*.

**Research anchors (approach, not code):**
- Lehrer & Gevirtz resonance-frequency breathing — each person has a breathing pace (~4.5–7 br/min) that
  maximises RSA amplitude / baroreflex gain; found by sweeping paces and reading the HRV response.
- *Sensors* 2023, 23(9):4494 — wearable haptic-paced slow breathing raises short-term HRV vs unguided.
- ACM ISWC 2025 (3715071.3750412) — wrist-haptic "buzz-below-HR" pacing entrains heart rate downward;
  just-in-time haptic micro-interventions reduce momentary stress.
- Task Force (1996) HRV definitions — already implemented in `HRVAnalyzer` (RMSSD/SDNN/pNN50).

---

## Goal & differentiation (why only NOOP)

WHOOP, Oura, Garmin, Apple Watch and Ultrahuman can *show* you HRV and *tell* you to breathe. None of
them can do all four of the things this pillar needs at once:

1. **Read raw beat-to-beat R-R locally, live.** NOOP already ingests R-R off the standard HR profile
   (`0x2A37`) and the custom stream, and computes RMSSD on-device (`HRVAnalyzer`, `BreathingView`).
2. **Drive the strap haptic motor.** NOOP has a hardware-confirmed buzz path
   (`MaverickHaptics.notificationBuzz` → `send(.runHapticsPattern)` on Apple, `WhoopBleClient.buzz` on
   Android) and a proven *scheduled* multi-pulse engine (`HapticClock` / `buzzTimeNow`).
3. **Close the loop on-device.** Measure → act → re-measure, all local, no cloud, no subscription.
4. **Run screen-off, hands-free.** The cue is *felt* on the wrist, so the user can close their eyes /
   pocket the phone. The Mac/iOS keep-awake hook already exists (`ScreenIdle.keepAwake`).

This pillar turns NOOP's existing **Breathe** screen (a fixed-pace HRV trainer with a post-session
outcome) into a **closed-loop biofeedback instrument** in three layers:

- **L1 — Personalised resonance breathing.** Find *this user's* resonance pace by sweeping 4.5–7 br/min
  and measuring which pace maximises their RSA/HF-HRV, lock it, then pace inhale/exhale via the haptic
  motor. Show "RMSSD +X over 10 min" after.
- **L2 — Buzz-below-heart-rate down-regulation.** During a stress spike, pulse the wrist at a tempo
  slightly **below** live HR to entrain HR downward (a felt metronome the heart drifts toward).
- **L3 — Closed-loop JITAI nudge.** Watch live HRV + recent motion; on a transient **non-metabolic** HRV
  dip (stress, not exercise), auto-fire a 60-second haptic breathing cue at the moment it matters.

All three are **off by default**, opt-in per layer, and rate-limited. Everything reuses the buzz path,
the HRV math, and the Breathe outcome capture that already ship.

---

## Data & signals used (what's already available vs new)

| Signal | Source | Status |
|---|---|---|
| Live beat-to-beat R-R (ms) | `LiveState.rr` / `setRRIntervals` (0x2A37 + custom stream) | **Have** |
| Rolling RMSSD / SDNN / pNN50 | `HRVAnalyzer.analyze` (Task Force 1996 + Malik cleaning) | **Have** |
| Live HR (bpm) | `AppModel.bpm` | **Have** |
| Worn / bonded flags (gating) | `LiveState.worn`, `LiveState.bonded` | **Have** |
| Haptic buzz (one-shot) | `MaverickHaptics.notificationBuzz` / `AppModel.buzz(loops:)` | **Have** |
| Scheduled multi-pulse haptics | `HapticClock` + `buzzTimeNow` (asyncAfter walk) | **Have (pattern to reuse)** |
| Recent motion (exercise gate) | offloaded gravity via `collector.recentGravity` (used by `SedentaryDetector`) | **Have** |
| Hourly autonomic stress proxy | `DaytimeStress` (HR-up + HRV-down z-score, 0–3 logistic) | **Have** |
| Existing resting stress nudge | `AppModel.evaluateStress()` (RMSSD vs slow EMA baseline, rate-limited buzz) | **Have (extend)** |
| **RSA amplitude per breathing pace** | new: peak-to-trough HR swing locked to the paced breath cycle | **New (engine)** |
| **Resonance-frequency estimate** | new: the swept pace that maximised RSA/HF-HRV | **New (engine, persisted pref)** |
| **Live "stress-onset" detector (JITAI)** | new: short-window RMSSD drop, motion-gated, edge-triggered | **New (engine)** |

**Honest limits we state up front:**
- WHOOP R-R is **PPG-derived**, not ECG — beat timing is good enough for trend RMSSD but is noisier than
  a chest strap. We already clean it (range + Malik ectopic). HF-HRV / RSA amplitude are therefore
  **estimates**, never clinical readings.
- The custom realtime stream usually reports `rr_count=0`; the **reliable** R-R is the standard profile.
  Resonance sweeps need a steady R-R feed, so the engine requires a minimum clean-beat rate and reports
  "not enough beat data" rather than guessing (mirrors Breathe's existing `"—"` behaviour).
- Each WHOOP notification buzz is a **fixed-length** motor pulse — we can't vary on-time per pulse, only
  *count* (stacked loops) and *timing*. Inhale = lighter cue, exhale = heavier cue, exactly as Breathe
  and Haptic Clock already do.

---

## On-device algorithm (grounded)

### L1 — Resonance-frequency detection + haptic pacing

**Detect (the sweep).** Resonance breathing theory (Lehrer/Gevirtz): there is a personal pace, usually
4.5–7 br/min, at which the 0.1 Hz baroreflex and respiratory sinus arrhythmia (RSA) align and the
heart-rate oscillation amplitude peaks. We find it by **pacing the user through candidate paces and
measuring the RSA response at each**:

1. Candidate paces (br/min): **4.5, 5.0, 5.5, 6.0, 6.5, 7.0** (cycle = 60/bpm; inhale:exhale ≈ 40:60,
   the calming long-exhale ratio Breathe's "Relax" preset already uses).
2. For each candidate, pace ~2 min via the haptic cue (below) while ingesting clean R-R.
3. Compute two response metrics per pace over its steady window (drop the first ~30 s transient):
   - **RSA amplitude** = mean peak-to-trough swing of the instantaneous HR (60000/RR) within each
     breath cycle, cycle boundaries known from the pacer. This is the resonance signal that peaks at the
     personal frequency.
   - **RMSSD** over the pace's clean beats (via `HRVAnalyzer`) as a corroborating short-term HRV value.
4. **Resonance pace = the candidate maximising a normalised RSA-amplitude score** (RMSSD breaks ties /
   sanity-checks). Persist as the user's `resonanceBreathsPerMin` (a pref, like any setting), with the
   measured RSA curve kept for the result screen.
5. Honesty gates: a pace with too few clean beats is unscored; if fewer than N paces score, we report
   "couldn't lock a resonance pace today — try again rested" and fall back to 5.5 br/min (coherence).

A full sweep is ~12–14 min; we also offer a **quick sweep** (4.5/5.5/6.5, ~7 min). Re-running overwrites
the locked pace. We never claim the pace is "your number forever" — it drifts; we date it.

**Act (the pacer).** A pure controller turns a target pace into a haptic schedule, reusing the
`HapticClock` "build a pulse list, walk it with `asyncAfter`, fire the proven buzz" pattern:

- Inhale onset → **1 light pulse** (`loops: 1`); exhale onset → **2 pulses** (`loops: 2`) — identical to
  Breathe today, so the felt language is already learned by existing users.
- The controller is a pure function `BreathPacer.schedule(bpm:, inhaleFraction:, cycles:)` → `[BreathCue]`
  (each `{ offsetMs, phase, loops }`), unit-testable with no I/O, exactly like `HapticClock.pulses`.
- The on-screen orb (when the screen is on) is driven by the same phase clock; screen-off, the buzz is
  the whole cue. Reduce-Motion path already exists in Breathe.

**Re-measure (the outcome).** Reuse Breathe's existing pre/post capture verbatim: baseline RMSSD locks
at start, session mean/peak stream, end-of-session line = `"+X% vs start · peak Y ms"`. For a resonance
session we additionally show the **locked pace** and its RSA curve.

### L2 — Buzz-below-heart-rate down-regulation

Goal (ISWC 2025): give the heart a felt metronome a few bpm **below** its current rate; HR tends to
drift toward an external rhythmic cue. Unlike L1 (breath-paced), L2 is **HR-paced**.

1. Trigger: an active stress spike (L3 detector fires, or the user taps "Calm me" on a high-stress
   moment). Requires bonded + worn + resting HR band (gate out exercise).
2. Read smoothed live HR `H₀`. Target tempo `T = H₀ − Δ`, Δ ramping from ~3 bpm to ~8 bpm over the
   session as HR follows (never below a floor, e.g. 50 bpm, and never more than ~12 bpm below live HR —
   a felt cue, not a shock).
3. Fire one light pulse per target beat (tempo `T`), recomputing `T` every ~15 s from the new smoothed
   HR so the cue *trails* the heart down rather than yanking it.
4. Stop when HR stabilises near a calm target, after a max duration (e.g. 3 min), or on user stop.
5. Outcome: "HR settled from H₀ to H₁ over Ns." Honest: if HR *didn't* fall, say so plainly — no
   fabricated success (consistent with the project's evidence-first rule).

`HRDownPacer` is a pure controller: `next(currentHR:, elapsed:, config:)` → next pulse interval (ms) +
whether to stop. No I/O, fully unit-tested on both platforms.

### L3 — Closed-loop JITAI nudge (the auto-trigger)

Extends the **existing** `evaluateStress()` (already: rolling R-R buffer + slow RMSSD EMA baseline +
rate-limited buzz) into an honest stress-**onset** detector that gates out exercise and fires a 60-s
guided breathing cue at the moment of a non-metabolic HRV dip.

Detector (`StressOnsetDetector`, pure):
1. Maintain a **slow** RMSSD baseline (EMA, the existing 0.98/0.02 smoothing) and a **fast** short-window
   RMSSD (last ~60 clean beats).
2. **Onset** = fast RMSSD drops below `baseline × dropRatio` (≈0.6, the shipped threshold) **and** the
   drop is a fresh **edge** (was above on the previous evaluation → fire once per event, not every tick).
3. **Exercise gate (the key correctness bit):** suppress when motion or HR says "this is metabolic, not
   stress":
   - HR outside the resting band (existing 55–100 bpm gate), **and/or**
   - recent gravity window shows movement (reuse `collector.recentGravity`, the same source
     `SedentaryDetector` uses) above an activity threshold.
   A metabolic HRV dip from a brisk walk must **not** fire a "you're stressed" cue — this is the honesty
   line that keeps the feature credible.
4. **Rate limit + quiet hours:** at most once per ~15 min (existing limiter), respect quiet hours and the
   master toggle, and never fire while a manual Breathe/L1/L2 session is already running.
5. On fire: a single confirming buzz, an optional 60-s haptic breathing cue at the user's locked
   resonance pace (or 5.5 default), and a passive in-app card ("HRV dipped while you were still — want a
   minute?"). **Never a push notification** unless the user explicitly opts into notifications — matches
   `DaytimeStress`'s "passive suggestion, never a notification" stance.

Output is a decision struct (`{ shouldNudge, reason, nextState }`) carrying its own de-dup state, exactly
like `SedentaryDetector.evaluate` — the app supplies honest inputs and persists `nextState`, so a
replayed window can't re-fire.

---

## Architecture & files (engine package + Kotlin twin + UI)

**Shared Swift engine** — new files in `Packages/StrandAnalytics` (serves mac + iOS), pure, no UI/BLE:

- `ResonanceEngine.swift` — RSA-amplitude per breath cycle, per-pace scoring, resonance-pace selection.
  Reuses `HRVAnalyzer` for RMSSD; depends only on `WhoopProtocol` types (`RRInterval`).
- `BreathPacer.swift` — pure pacer: `(bpm, inhaleFraction, cycles) → [BreathCue]`. Mirrors `HapticClock`'s
  encoder shape (Pulse-list out, no I/O), so the existing `asyncAfter` walk drives it.
- `HRDownPacer.swift` — L2 controller: `next(currentHR:, elapsed:, config:) → (intervalMs, stop)`.
- `StressOnsetDetector.swift` — L3 detector with embedded de-dup state, gravity/HR exercise gate;
  generalises the math currently inline in `AppModel.evaluateStress()`.

**Kotlin twins** — value-for-value in `android/app/src/main/java/com/noop/analytics/`:
`ResonanceEngine.kt`, `BreathPacer.kt`, `HrDownPacer.kt`, `StressOnsetDetector.kt`. The repo already
keeps such twins in lock-step (`HapticClock.kt`, `HrvAnalyzer.kt`, `DaytimeStress.kt`,
`SedentaryDetector.kt`), pinned by matching golden-vector tests on both sides.

**Wiring (per platform, thin):**
- Apple: a `BiofeedbackController` (in `Strand/`, like the Breathe view's session logic) owns the live
  session — pulls `LiveState.rr`, calls the engine, walks the cue list firing `AppModel.buzz`/
  `send(.runHapticsPattern)`. L3 hooks into the **existing** `evaluateStress()` call site
  (`AppModel.swift:320`) and the gravity read used by `maybeBuzzInactivity()`
  (`BLEManager.swift:1769`). Keep-awake via `ScreenIdle.keepAwake`.
- Android: same controller logic in the `ui`/`ble` layer, firing `WhoopBleClient.buzz` /
  `buzzTimeNow`-style scheduled writes.

**Reuse, don't rebuild:** `HRVAnalyzer`, `BreathingView` (orb, outcome capture, status pills, Reduce
Motion), `MaverickHaptics.notificationBuzz`, `HapticClock`'s scheduling pattern,
`AppModel.buzz`/`evaluateStress`, `DaytimeStress` (for the stress context the JITAI card shows),
`collector.recentGravity` (exercise gate), `ScreenIdle.keepAwake`, `BehaviorSettings` toggles.

---

## Cross-platform plan

Per the project's cross-platform parity rule, every change reaches **all three** clients:

- **Engines (mac + iOS):** automatic — shared Swift package `StrandAnalytics`, non-excluded.
- **Android:** hand-ported Kotlin twins, each pinned to the Swift version by an identical golden-vector
  test (a fixed R-R series → identical resonance pace + identical cue list; a fixed HR trajectory →
  identical `HRDownPacer` intervals; a fixed RMSSD/motion sequence → identical JITAI fire decision).
- **UI:** per platform (SwiftUI extends `BreathingView` / `MindSection`; Compose extends `BreatheScreen`
  / `StressScreen`). Honest parity of *behaviour and copy*, native of *presentation*.
- **Build/verify centrally once** across mac/iOS/Android (don't serialise gradle per-agent). If a layer
  fails to land on one platform, back it out on all to keep parity (the project's standing rule).

---

## UX (screens/flows, honest + skimmable)

**Where it lives:** the existing **Breathe** screen (under Mind) becomes the home of all three layers via
a mode switch; L3's auto-nudge surfaces as a passive card on Today/Stress.

**L1 — Resonance (Breathe → "Find my pace" / "Resonance" mode):**
- A one-time **"Find your resonance pace"** flow: explainer card → "Start sweep" (full ~13 min /
  quick ~7 min) → the existing orb paces each candidate while a small "Testing 5.5 br/min…" label and a
  live RSA-amplitude bar update → result card: **"Your resonance pace: 5.5 br/min"** + the RSA-vs-pace
  curve + date. Honest empty state if it couldn't lock.
- After locking, the default Breathe session uses the personal pace; the preset pills (Relax / Coherence
  / Box) remain, with a new **"Resonance 5.5"** pill that reads the locked value.
- Post-session outcome reuses today's line: `"+18% vs start · peak 64 ms"`.

**L2 — "Calm me" (button on a high-stress moment + inside Breathe):**
- A button on the Stress screen / JITAI card: **"Calm me · 3 min."** Starts L2 with a felt
  below-HR metronome and a minimal screen ("HR 78 → settling", live, screen-off friendly).
- Outcome: "HR settled 78 → 69 over 2:30." If it didn't fall: "HR held steady — try a paced breath
  instead" (offers L1). No fake wins.

**L3 — Auto-nudge (passive):**
- Settings → Mind: **"Stress check-ins (haptic)"** master toggle (default **off**), with sub-toggles for
  *auto-nudge*, *quiet hours*, and *use my resonance pace*. Plain-language explainer: "When your HRV dips
  while you're still (not exercising), your strap can offer a one-minute breathing cue. It's relaxation
  guidance, not a health alert."
- When it fires: one confirming buzz + a dismissible card ("Your HRV dipped while you were still — want a
  minute to breathe?") with **Breathe now / Not now / Turn off**. Never an alarm, never a diagnosis.

**Accessibility:** screen-off operation is the headline a11y win (no visual attention needed). Reduce
Motion already suppresses the orb zoom; the haptic + phase word carry the cue. Icon buttons get
`aria`/accessibility labels; the RSA curve has a text summary.

**Connection honesty:** every layer shows the existing "Haptics on / Visual only" pill. Unbonded =
visual-only with the existing "connect your strap for haptic guidance" hint; L2/L3 (which are
haptic-first) are disabled, not faked, when unbonded.

---

## Non-clinical / legal framing (wellness-only)

Carried in copy, the spec, and `DISCLAIMER.md`/`TERMS.md` posture:

- **Guided breathing and relaxation — not a medical device, not a treatment, not diagnostic.** Never
  "treats anxiety/stress/arrhythmia/anything." Verbs are *guide, pace, relax, settle, suggest* — never
  *diagnose, treat, cure, monitor for disease.*
- **"Stress" = an autonomic proxy, not a diagnosis.** Reuse `DaytimeStress`'s existing framing: HR-up /
  HRV-down vs the user's own baseline; "estimate only," "trends matter more than any single number,"
  "not a clinical reading." The JITAI card says "HRV dipped while you were still," never "you are
  stressed" / "you have a problem."
- **HRV/RSA are estimates from PPG-derived R-R**, stated wherever shown. No HF/LF power claims dressed as
  clinical metrics.
- **Outcomes are honest.** "+X% RMSSD vs start" is *this session's measured change*, not a health
  benefit. We never claim a number went up means the user is healthier.
- **Buzz-below-HR is a relaxation metronome**, not cardiac control: bounded Δ, HR floor, never below a
  safe rate, auto-stop, user-stoppable. No claim it "lowers your heart rate" as a therapeutic outcome —
  it offers a rhythm to relax toward.
- **All three layers default OFF, opt-in, quiet-hours-aware, rate-limited.** Manual-first ethos.
- **Anonymous:** no AI/LLM mentioned anywhere in shipped copy (the only AI surface remains the opt-in
  bring-your-own-key AI Coach). Pricing/comparisons in **USD**.
- **No data leaves the device.** Resonance pace + session outcomes are local prefs/records; nothing
  uploaded.

---

## Test plan

**Engine unit tests (Swift in `StrandAnalytics` tests + Kotlin twins, golden-vector pinned):**
- `BreathPacer`: a fixed `(bpm, inhaleFraction, cycles)` → exact `[BreathCue]` list (offsets, phase,
  loops). Cross-platform identical (the `HapticClock` precedent).
- `ResonanceEngine`: synthetic R-R with a known RSA peak injected at one pace → engine selects that pace;
  too-few-beats pace → unscored; <N scored paces → "no lock" fallback to 5.5.
- `HRDownPacer`: a scripted HR descent → monotonic, bounded target intervals; respects HR floor and
  max-Δ; stops on stabilise/timeout.
- `StressOnsetDetector`: edge-trigger (fires once on the drop, not each tick); **exercise gate**
  (HR-out-of-band and/or motion → suppressed); rate-limit + quiet-hours honoured; de-dup state replays
  safely (a re-fed window can't re-fire). This is the highest-value test — it guards the credibility line.
- Reuse the existing RMSSD/cleaning coverage in `HRVAnalyzer`/`HrvAnalyzer` tests; assert L1/L3 call into
  it rather than re-deriving HRV.

**Cross-platform parity tests:** the same fixed input vectors produce byte/number-identical outputs in
Swift and Kotlin (a `ParityTests`-style pair), so the twins can't drift.

**Manual / on-device (haptics are unverifiable in simulator — test on a real strap):**
- L1 felt cue matches the orb; resonance lock persists across relaunch; outcome line correct.
- L2 metronome trails HR down without yanking; bounded; stops correctly; honest "didn't fall" path.
- L3 fires on a real induced stress moment (cold-pressor / mental arithmetic) and **does not** fire on a
  brisk walk (the gate). Evidence = a captured strap log + the in-app card, not just a build pass.

---

## Phasing

**MVP (Phase 1 — ship first):**
- `BreathPacer` + `ResonanceEngine` (full + quick sweep) + L1 UI in Breathe (resonance lock, RSA curve,
  reuse the existing outcome capture). This is the flagship, builds directly on the shipped Breathe
  feature, and is the lowest-risk (manual, user-initiated).
- Kotlin twins + parity tests for both engines.

**Phase 2:**
- `StressOnsetDetector` (L3) — generalise `evaluateStress()`, add the gravity/HR exercise gate, the
  edge-trigger, the passive card, and the master/sub toggles. Defaults off.

**Phase 3:**
- `HRDownPacer` (L2) — "Calm me" below-HR metronome, wired into the Stress screen and the L3 card.

**Later / exploratory:**
- Weekly "your resonance pace this week" trend in the Weekly Digest; correlate paced-breathing sessions
  with next-day Charge (reuse `CorrelationEngine`, honestly framed); optional longer guided programmes.

---

## Open questions

1. **R-R sample rate for RSA.** Is the standard-profile R-R cadence dense enough to resolve per-cycle RSA
   amplitude cleanly at 4.5–7 br/min, or do we need the custom stream when it actually carries beats?
   (Decides whether the full sweep is trustworthy or we ship quick-sweep-only first.) — needs an
   on-strap capture.
2. **Buzz timing fidelity.** Fixed-length motor pulses: is the inhale/exhale (1 vs 2 loops) distinction
   crisp enough to pace at slow paces without the exhale's two pulses bleeding into the next inhale?
   Confirm on a real motor; may need a longer inter-phase gap than Breathe uses.
3. **Exercise-gate source latency.** Gravity is *offloaded* (lags ~7–15 min via `recentGravity`), so the
   L3 gate may see motion late. Is the resting-HR-band gate sufficient on its own for real-time
   suppression, with gravity as a secondary confirm? Or do we need a lighter live-motion signal?
4. **L2 safety envelope.** Final numbers for max Δ-below-HR, HR floor, and max duration — conservative
   defaults pending a small self-test; should these be user-adjustable or fixed for safety?
5. **iOS background reality.** L3 needs to evaluate while the phone is idle; iOS suspends timers. Does the
   existing BLE-connected foreground/keep-awake model cover the realistic use (phone on desk, app
   foreground), and do we explicitly scope L3 to "app active" on iOS (macOS runs continuously)?
6. **Resonance-pace drift cadence.** How often to re-prompt a re-sweep (monthly? on a big Charge/baseline
   shift?) without nagging — and do we ever auto-suggest it, or keep it fully manual?
