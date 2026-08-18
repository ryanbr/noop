# Sleep vs wake heart-rate contrast

`SleepHeartRateContrast` (StrandAnalytics + `com.noop.analytics` twin) is a small, descriptive engine
that compares mean HR during an explicitly supplied **primary-sleep** window against mean HR during an
explicitly supplied **wake** window. It is wellness context, not a clinical measure.

## What it is not

- **Not a resting-heart-rate definition.** NOOP already ships a floor-style RHR (the scoring input) and
  collects a separate primary-session mean RHR candidate (#1174/#1188; evidence in #1169, which also
  records that a lowest-30-minute candidate performed *worse* than the primary-session mean). This engine
  adds no third RHR and changes neither of the existing ones.
- **Not a dipping classifier.** It emits no dipper / non-dipper / reverse-dipper / riser label, no
  cardiovascular-risk category, and no diagnostic threshold. Those concepts do not transfer from
  blood-pressure/physiology contexts to wearable HR just because a percent difference can be computed.
- **"Sleep vs wake", not "night vs day".** It does not assume everyone sleeps at night; the caller owns
  window selection, where primary-session detection, local-time semantics and shift schedules live.

## Input contract

Both inputs are fixed-cadence epoch arrays (`[Double?]` / `List<Double?>`), one element per expected
equal-duration epoch:

| element | meaning |
|---|---|
| valid bpm (`30…220`) | observed HR for that epoch |
| `nil` / `null` | unobserved epoch |
| out-of-range bpm | invalid for this metric (treated as unobserved) |

Missing/invalid epochs are **never imputed** — they only lower coverage. The mean is an unweighted
arithmetic mean over valid epochs, which equals a time-weighted mean only because the grid is fixed;
irregular raw streams should be aggregated onto a declared cadence first.

## Output

For wake mean `W` and primary-sleep mean `S`:

- `sleepMinusWakeBpm = S − W` (negative ⇒ lower HR during sleep)
- `sleepReductionPercent = 100 · (W − S) / W` (positive ⇒ lower HR during sleep)
- per-window `validSamples`, `totalSamples`, `coverage`

## Gating

`minimumValidSamples` (default 30) is applied **independently to each window**; `evaluate` returns nil
unless both sides clear it. The default mirrors the provisional 30-valid-sample floor of the
primary-session mean RHR experiment and is **not** a clinically validated coverage threshold — a future
product surface should weigh cadence, represented duration, and coverage before showing a result.

## Status

Pure engine with cross-platform parity tests. No consumer wires it in yet: something must build the
fixed-grid wake and primary-sleep HR windows before a result can be shown. That window-construction is
deliberately out of scope here.
