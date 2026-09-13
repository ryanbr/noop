# Predictive low-battery notification — design

**Date:** 2026-07-10
**Scope:** macOS + iOS shared layer (`Strand/System/BatteryNotifier.swift`, `Strand/App/AppModel.swift`)
plus a pure policy in `Packages/StrandAnalytics`. Android twin deferred until this is upstreamed —
`BatteryAlertPolicy` is documented behavior-identical with the Kotlin twin (#368), so an upstream PR
must carry the Kotlin `runtimeAlert` policy + tests to honor the parity contract.

## Problem

The existing low-battery alert (#368) fires at a fixed 15% state of charge. Runtime at 15% differs
by strap generation — ~16 h on a WHOOP 4.0 but ~1.8 days on a 5.0/MG — so the warning's lead time is
an accident of hardware. Meanwhile `BatteryEstimator` (#713) already produces a personalized
"~X left" runtime estimate from the strap's banked discharge history. The two are not connected.

## Behavior

- On every battery reading (`LiveState.onBatteryUpdate` → `AppModel` hook), evaluate the current
  `LiveState.batteryEstimate` against a new pure policy:
  - **Fire** when `remainingHours <= 24`, the strap is not confirmed charging (`charging != true`,
    matching the low alert's null-tolerant rule), and the runtime gate is armed.
  - **Re-arm** only when `remainingHours >= 36` — estimate jitter around the 24 h line cannot
    re-fire; only a genuine charge recovers 12+ hours of headroom.
  - Both estimate sources fire (`measured` and `rated`): the estimator's own gates (`minSpanHours`,
    `minDropPct`, near-full anchoring) already reject junk fits, and a rated-fallback estimate is
    still generation-correct.
- Notification: id `battery-runtime`, title "Strap battery low", body built from
  `BatteryEstimator.label(hours:)` — e.g. "~22h left on your WHOOP — recharge tonight."
- The `runtimeAlerted` gate is persisted (`behavior.batteryRuntimeAlerted` in UserDefaults), like
  `lowAlerted`/`fullAlerted`, so the once-per-discharge-cycle guarantee survives process death, and
  it advances even when delivery is deferred (authorization declined), mirroring #368.
- **Unchanged:** the 15% low alert (safety net — covers the nil-estimate case), the 100% full note,
  the existing "Battery alerts" setting gating everything (no new setting), and
  `BatteryNotifier.requestAuthorization()`.
- A user near the boundary may receive the runtime alert (≤24 h) and later the 15% alert in the same
  discharge — accepted: they carry different messages (plan vs act), and deduplicating them would
  couple the two gates.

## Where the code goes

- `BatteryEstimator.runtimeAlert(remainingHours:charging:alerted:)` in `StrandAnalytics` — pure
  `(fire, newAlerted)` decision with the 24/36 constants (`runtimeAlertHours`, `runtimeRearmHours`).
  `swift test` covered: fire, jitter no-refire, re-arm on recovery, charging suppression (`nil`
  charging still fires), nil-estimate no-op at the caller.
- `BatteryNotifier.onRuntimeEstimate(remainingHours:charging:enabled:)` — reads/writes the persisted
  flag, posts via the existing `post` helper.
- `AppModel`'s existing `live.onBatteryUpdate` closure additionally calls `onRuntimeEstimate` with
  `live.batteryEstimate?.remainingHours`.

## Testing

Policy: `swift test` in StrandAnalytics. Notifier/UI glue: compile both app schemes (no default CI
covers app targets); on-hardware check is watching the alert land when the strap next runs down.
