# Apple Health high-resolution write-back — design

**Date:** 2026-07-10
**Scope:** iOS only (`StrandiOS/Health/HealthKitBridge.swift` + a pure helper in
`Packages/StrandImport`). Android Health Connect write-back is explicitly deferred — no analytics
or stored-data change, so the byte-parity contract is not triggered.

## Problem

`HealthKitBridge.writeBack` writes only four daily quantity samples (resting HR, HRV SDNN, SpO₂,
respiratory rate), each stamped at a fabricated noon timestamp. It requests share permission for
`sleepAnalysis` but never writes a sleep sample, so a user coming from Oura (which writes full
sleep sessions with stages) sees an empty Sleep section in Health. No heart-rate stream, no
workouts.

## What gets written

| Feature | NOOP source | HealthKit output | Idempotency key |
|---|---|---|---|
| Sleep sessions | `WhoopStore.sleepSessions` — computed (`deviceId+"-noop"`) unioned with imported (`deviceId`), imported wins on `startTs` | One `.inBed` sample spanning `effectiveStartTs→endTs`, plus one `HKCategorySample` per stage segment: `deep→.asleepDeep`, `rem→.asleepREM`, `light→.asleepCore`, `wake`/`awake`→`.awake`. Sessions without `stagesJSON` get one `.asleepUnspecified` block. | `noop:<deviceId>:sleep:<startTs>` on every sample of the session |
| Heart rate | `WhoopStore.hrBuckets(bucketSeconds: 60)` under the strap device id (measured-first with PPG fallback, same read the charts use) | 1-minute `heartRate` samples, 24/7. Raw 1 Hz deliberately downsampled: ~86–170k samples/day would bloat the Health store; 1/min matches Apple Watch background cadence and beats Oura's 5-min. | Forward-only cursor in UserDefaults (`hkHRWriteCursor.v1.<deviceId>`) + a 48 h rewrite window: each run deletes NOOP-authored HR in the window (source-scoped, date-range predicate) and rewrites, so late strap offloads inside 48 h reconcile. First run backfills the full 14-day window. |
| Workouts | `WhoopStore.workouts` for both device ids, **excluding** `source == "apple-health"` (those were imported FROM Health — writing them back would duplicate) | `HKWorkoutBuilder` workout with reverse-mapped `HKWorkoutActivityType`, an `activeEnergyBurned` sample when `energyKcal` is present, a distance sample for distance sports when `distanceM` is present. | `noop:<deviceId>:workout:<startTs>` in workout metadata; delete-then-write on `workoutType()` |
| Nightly vitals (existing) | unchanged | unchanged types, but stamped at the day's sleep-session end (wake time) when one exists instead of fabricated noon | unchanged (`noop:<deviceId>:<hkid>:<day>`), so re-stamping replaces cleanly |

## Deliberately excluded

- **Raw 1 Hz HR** — Health-store bloat; 1-min mean via the existing `hrBuckets` SQL is the ceiling
  that stays usable.
- **Skin temperature** — NOOP stores only a deviation from baseline (`skinTempDevC`), not absolute
  °C; `appleSleepingWristTemperature` is not third-party-writable and writing a fabricated absolute
  `bodyTemperature` would be dishonest data.
- **Daily steps / active-kcal estimates** — approximate HR-only estimates that would double-count
  against the phone/watch in Activity totals. Honest energy goes on the workouts.

## Authorization migration

`writeTypes` grows by `heartRate`, `activeEnergyBurned`, `distanceWalkingRunning`,
`distanceCycling`, and `workoutType()`. Two consequences handled explicitly:

1. `refreshAuthIfPreviouslyGranted` (resume without prompting) checks `allSatisfy(.sharingAuthorized)`
   over `writeTypes` — a returning user who granted the old set would never resume. Fix: resume when
   the **legacy core set** (4 vitals + sleep) is authorized; if the new types are still
   `.notDetermined`, fire one `requestAuthorization()` so HealthKit shows a single sheet listing only
   the new types.
2. Every write feature guards on its own type's `.sharingAuthorized` and saves independently — a
   denied checkbox for one type can no longer sink the whole write-back. First error is kept for
   `lastError`; remaining features still run.

## Feedback-loop safety

The read path (`collect*`, `fetchTouchedDayWindow` observers) already filters
`notNoopAuthored` (`NOT source == HKSource.default()`), so NOOP's own writes neither re-import nor
wake the observers. Verified against the current predicates.

## Testing

- Stage-segment parsing/clamping/normalization is a pure function in `Packages/StrandImport`
  (`HealthWriteback.stageIntervals`) with `swift test` coverage: valid JSON, nil/garbage JSON,
  `wake` vs `awake` vocab, segments clamped to session bounds, zero-length segments dropped.
- HealthKit itself is not unit-testable; app-target changes are verified by compiling `NOOPiOS`
  locally (no default CI covers app targets per CLAUDE.md).
