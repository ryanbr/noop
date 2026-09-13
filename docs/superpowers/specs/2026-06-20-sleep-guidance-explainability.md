# Sleep & Recovery Guidance / Explainability Layer — Design

**Status:** APPROVED (2026-06-20). Scope = all five components. Ships together with the sleep overhaul as 6.0.2 once both are verified to 99%.

## Goal

Make NOOP foolproof. People should never have to guess whether something is working, whether a score is coming, or why a value was chosen. Every uncertain or derived value gets a clear state, a plain-English reason, and a next step. Honest always: never fabricate a number, always show where one came from.

## Principle (the one rule)

**No bare number without a STATE, a REASON, and a NEXT STEP.**
Plain English, no jargon, no em-dashes. Swift and Kotlin must say the *same words* and use the *same logic*.

## Foundation (shared, lands before the UI lanes)

1. **Main-night selection reason.** Extend the selector to expose WHY the main block won, as an enum the UI renders verbatim, computed in `SleepStageTotals` alongside `mainNightIndex` (both platforms) so the reason is the exact truth the selector used:
   - `onlyBlock` — "This is your only sleep block today."
   - `longest` — "your longest block (Xh Ym)." (cold-start / no learned timing yet)
   - `longestNearUsual` — "your longest block (Xh Ym), and it started near your usual bedtime."
   - `alignedToUsual` — "it started near your usual sleep time" (when alignment, not raw duration, decided the pick).
   Each carries the chosen block's asleep duration so the copy can fill Xh Ym.

2. **Score-state model.** A shared enum per score/tile, derived honestly from baseline readiness + data presence + the existing #543 carry-over:
   - `scored(value)` — today's own value exists.
   - `calibrating(nightsRemaining)` — baselines still cold-start (< the personal-baseline threshold of nights).
   - `carriedLastNight(date)` — prior scored day shown pre-tonight (the #543 carry-over).
   - `needsStrap` — no data for the period (strap not worn / not connected / not synced).

3. **Recording-state model.** "Recording" / "Last synced Xm ago" / "Not recording (reason)" from the BLE connection state + last-sync timestamp.

## Components

1. **Why-this-is-your-main-sleep explainer** (Sleep tab). Tappable info on the hero and each nap row → the reason from the foundation + an Edit nudge: *"Main sleep because it was your longest block (7h 12m), near your usual bedtime. Your 45-min afternoon block is logged as a nap. Wrong? Tap Edit."* Directly answers #547 (pikapik).
2. **Explained score states** (Today). Each score/tile renders its state instead of a bare blank: **Calibrating — N more nights**, **Last night · <date>**, **Needs the strap — was it worn + connected overnight?**, each with one line of what-to-do.
3. **Recording status** (Today / Live). A clear, honest chip/banner so people know it's working, or know it isn't and why.
4. **Provenance** (extends the By-Day badge already built). On-device / Whoop / Apple Health on every derived number, reflecting the REAL per-day merge winner.
5. **"How NOOP works" primer** (new sheet, reachable from a "?"). Skimmable: how sleep classification works, how scores + calibration work, what recording means, what the provenance badges mean.

## Honesty rules

- Never fabricate a value. `calibrating` / `needsStrap` show no fake number.
- Carried values are always stamped with their date.
- Provenance is the real merge winner (computed vs imported), never a blanket "on-device."
- Copy is plain English, no jargon, no em-dashes.

## Cross-platform + file lanes

- Foundation (reason enum, state/recording models) in shared analytics where possible; wording mirrored exactly Swift/Kotlin.
- Swift lanes: `TodayView.swift`, `SleepView.swift`, new `HowNoopWorks` primer.
- Kotlin lanes: `TodayScreen.kt`, `SleepScreen.kt`, new primer composable.

## Testing

- Reason enum: a unit test per branch (only-block, longest, longest-near-usual, aligned), both platforms.
- State model: unit tests (calibrating count, carry-over, needs-strap), both platforms.
- Central build-verify all three platforms; no agent runs gradle.
