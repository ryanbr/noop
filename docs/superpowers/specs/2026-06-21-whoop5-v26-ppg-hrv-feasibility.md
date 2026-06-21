# WHOOP 5 v26 PPG → HRV: Feasibility Harness & Design

**Date:** 2026-06-21
**Status:** Design + Phase-0 harness proposed. NOT a shipped feature. Engages an existing in-code claim — see §1.
**Relates to:** #156 (v26 PPG decode), #553 (`burst_index`), #194 (withdrawn PPG→HR autocorrelation artifact), `PpgHr`, `HRVAnalyzer`.

---

## 1. The open question (not a foregone feature)

`PpgHr.swift`'s header records the contributor's finding that the v26 optical buffer is **"HR-only … NOT HRV (the contributor confirmed v26 gives no RMSSD)."** This spec does **not** contradict that — it proposes the experiment that would either **confirm it with numbers** or **overturn it with a same-device ground-truth match.** Today the claim is qualitative; the value here is to make it quantitative and decidable.

Why it's worth testing rather than assuming:
- The most likely reason v26 "gives no RMSSD" is **time resolution**: at 24 Hz one sample spans **~41.7 ms**, while a real RMSSD is often **20–50 ms**. Integer-sample beat timing would therefore be quantisation-dominated — RMSSD swamped by ±42 ms grid noise. That is a *fixable* failure mode (sub-sample peak interpolation), not a fundamental one — **if** the waveform is smooth enough for interpolation to recover beat timing to a few ms.
- We have an unusually strong arbiter: **v18 records carry the strap's own R-R intervals.** A session with both v18 and v26 lets us compare v26-PPG-derived RMSSD against v18-strap-R-R RMSSD on the **same device, same night, no cloud, no official app.** That sidesteps the #194 trap (one matched value ≠ validation).

## 2. Why a new detector, not `PpgHr`

`PpgHr` derives an **average rate per window** by autocorrelation. RMSSD is the RMS of successive R-R **differences** — it needs individual systolic beat *times*, which autocorrelation structurally cannot produce. Autocorrelation is also the exact #194 failure: autocorrelating concatenated fixed-24-sample records manufactures a lag-24 (=60 bpm) peak. So `PpgHr` stays an independent **cross-check**, never the source. (Its `removeRecordRateComponent` / `detrend` pre-filter is reused so the new detector inherits the #194-safe front-end.)

## 3. Pipeline (Phase 0 — `PpgBeats`)

Per **burst** (a continuous run of consecutive-second v26 records; never cross a gap/`burst_index` reset):
1. **Concatenate** the run's 24-sample records in time order → one evenly-sampled waveform.
2. **Pre-filter:** `PpgHr.removeRecordRateComponent` (no-op on a smooth pulse, kills a per-record DC/phase-reset comb) → `PpgHr.detrend` (DC + linear/baseline wander).
3. **Detect systolic peaks:** local maxima above an adaptive RMS threshold, with a refractory period = `rrMin` (300 ms = 7.2 samples) so dicrotic notches don't double-count.
4. **Sub-sample refinement (the make-or-break step):** parabolic interpolation of each peak's location → fractional-sample timing. Without this the whole thing is grid noise.
5. **R-R (ms)** = successive refined-peak spacing × (1000/24).
6. Hand raw R-R to the existing **`HRVAnalyzer.analyze(rawRR:)`** (range + Malik ectopic clean, ≥20 beats → RMSSD/SDNN/pnn50). One ~40 s burst at 60–100 bpm yields ~40–65 beats > the 20-beat floor → one spot RMSSD per burst.

## 4. Validation (how we avoid repeating #194)

The harness is the deliverable, not a feature. Decisive tests, in order of strength:
1. **v18-R-R cross-check (the arbiter).** For sessions with both layouts, compare v26-PPG RMSSD vs v18-strap-R-R RMSSD across windows. Agreement across multiple windows/sessions = real. Disagreement = the claim stands, now with evidence.
2. **Quantisation-floor measurement (Phase 0, synthetic).** Inject an R-R series of *known* RMSSD into a synthetic 24 Hz PPG, run it back through `PpgBeats`, and measure recovered-vs-injected RMSSD **with and without** sub-sample refinement. This empirically answers "can 24 Hz even represent this RMSSD?" before any hardware.
3. **HR-state separation.** Synthesise 50 bpm vs 100 bpm; recovered R-R must track (≈1200 ms vs ≈600 ms). An artifact pinned to record length would not separate.
4. **60 bpm not snapped.** A smooth 60 bpm pulse (period = 24 samples, the #194 danger zone) must recover ≈1000 ms, not collapse onto the record-rate comb.

"One matched night" is explicitly **not** acceptance — require #1 across varied HR + multiple sessions.

## 5. Phasing

- **Phase 0 (this PR):** pure `PpgBeats` detector + the synthetic harness (§4.2–4.4). No app surface, no wiring. Outcome = a *measured* answer to "is the resolution good enough," independent of hardware.
- **Phase 0.5:** behind a debug flag, emit v26-derived R-R alongside v18 R-R for the same session and log the comparison (§4.1) — gather field signal, no user-facing HRV.
- **Phase 1 (only if Phase 0.5 holds):** surface v26 overnight HRV → WHOOP 5 recovery. Swift-first (reference decoder); Android/Linux parity port then finally has a consumer.

## 6. Honest limitations

- **PPG HRV ≠ ECG HRV** — pulse-rate variability carries extra variance (pulse-transit-time); label any output *pulse-derived* (as WHOOP's own app effectively is).
- **Motion** — gate bursts by `PpgHr` autocorrelation confidence (≥0.3); only clean (typically still/sleep) bursts qualify, which is the overnight-HRV use case anyway.
- **Sparsity** — ~one burst / 19 min → spot HRV, best in sleep windows.
- **The 24 Hz floor may simply be too high.** If §4.2 shows the recovered RMSSD error exceeds the signal even on clean synthetic data, that confirms the contributor's claim and the effort stops here — which is itself a useful, documented result.
