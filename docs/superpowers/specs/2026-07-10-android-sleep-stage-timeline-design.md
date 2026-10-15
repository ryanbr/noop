# Android Sleep "Stage breakdown" — mirror iOS #988 stage-timeline rows

This is the historical design record. The maintained implementation is in
[`SleepScreen.kt`](../../../android/app/src/main/java/com/noop/ui/SleepScreen.kt),
[`SleepStageTimelineLogic.kt`](../../../android/app/src/main/java/com/noop/ui/SleepStageTimelineLogic.kt) and
[`SleepStageBreakdownUi.kt`](../../../android/app/src/main/java/com/noop/ui/SleepStageBreakdownUi.kt),
with [interval](../../../android/app/src/test/java/com/noop/ui/StageTimelineIntervalsTest.kt),
[smoothing](../../../android/app/src/test/java/com/noop/ui/StageDisplaySmoothingTest.kt) and
[row-span](../../../android/app/src/test/java/com/noop/ui/StageRowSpansTest.kt) tests.
The [original completed execution recipe](https://github.com/ryanbr/noop/blob/5e8f0e8b33df470d4a12c86b04083acb18775794/docs/superpowers/plans/2026-07-10-android-sleep-stage-timeline.md)
is retained in Git history; the design and useful manual checks remain here.

**Date:** 2026-07-10
**Scope:** Android `SleepScreen` hero card only — graph + legend. `MotionStrip` component unchanged.
**Decision trail:** user approved mirroring iOS's WHOOP sleep-details layout (ryanAtriumAi #988,
`Strand/Screens/SleepView.swift:640-1290`) instead of building a 4-lane stepped hypnogram, because iOS
already removed the 4-level staircase — fragmented on-device staging turned it into an unreadable comb.

## Problem

The Android hero card renders the night as one flat proportional strip (`HypnogramWithAxis`) that is hard
to read, plus TWO legends carrying the same numbers: a colors-only dot row (`StageLegend`) under the
`MotionStrip`, and a footer (`StageBreakdownRows`: swatch + % + LiquidTube + duration). iOS already moved
to per-stage timeline rows where "the rows ARE the legend". The platforms have diverged.

## Design

### Real-stage nights (`display.realSegments != null`, ≥ 2 segments)

Replace the card body (`SleepScreen.kt:829-856`) with an Android `StageTimeline`, mirroring
`SleepView.stageTimeline` minus the HR chart and headline pair (see Non-goals):

1. **Four per-stage timeline rows**, WHOOP order **AWAKE · LIGHT · DEEP · REM**
   (mirrors `stageTimelineRow`, `SleepView.swift:1204`):
   - Header: `STAGE` overline + colored `%` + right-aligned duration. Percent basis stays
     `minutes / s.total` (all four rows, awake included) — same as today and same as iOS.
   - Track: full-width hatched track = the whole night; solid rounded segments (min width 2dp,
     corner 1.5dp, height 20dp) where that stage occurred, positioned on the shared onset→wake axis.
   - Row chrome: 10dp rounded background at `textPrimary` 4.5% alpha; selected row gets a
     `hairlineStrong` 1.5dp stroke.
   - **Tap to highlight**: `selectedStage` state; tapping a row dims the other rows' segments to
     `textTertiary` at 55% alpha and their `%` tint to tertiary. Tap again to clear.
   - a11y: one collapsed node per row — "Awake: 49 min, 10 percent of the night", hint
     "Highlights this stage on the sleep chart", button trait. Mirrors iOS exactly.
2. **Display smoothing**: port `Hypnogram.displaySmoothed(minDuration: 90)` (90 s floor) from
   `Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift` as a pure Kotlin function. Rows tolerate
   fine texture, so 90 s (not the staircase's 300 s).
3. **Intervals from segments**: Android's `realSegments` is an ordered `List<Pair<String, Float>>`
   (name, weight). Reconstruct `(stage, startSec, endSec)` intervals by walking cumulative fractions
   across `wakeTs - effectiveStartTs`. Pure function, unit-tested.
4. **Time axis**: keep the existing onset · midpoint · wake clock-label row (reuse the
   `HypnogramWithAxis` axis code), aligned with the rows' inner track insets.
5. **MotionStrip**: component and data path untouched. Moves to directly UNDER the four rows, above the
   clock-label row's insight slot — same timeline, same left/right insets as the rows' tracks so epochs
   line up (iOS anchors `motionStrip` the same way, `SleepView.swift:700`). Rendered only in this
   real-timeline branch, mirroring iOS: the proportional fallback bar has no timeline to anchor to.
6. **Per-stage insight slot**: fixed-height caption under the axis — with a stage selected, that stage
   tonight; otherwise the quiet "tap a row" hint. Fixed height so selection never reflows the card.
   (30-day typical comparison ships only if the repo call already exists on Android; otherwise the slot
   shows tonight's value and the typical-range compare is a follow-up.)

Both legends die in this branch: dot `StageLegend` row deleted, `ChartCard` footer dropped
(`StageBreakdownRows` no longer called here) — the rows are the legend.

### Fallback nights (reconstructed architecture / minutes-only, < 2 real segments)

Mirror iOS's else-branch (`SleepView.swift:657-665`): keep the flat proportional strip (existing shared
`Hypnogram` geometry) as the chart with subtitle "approx. stages (on-device)", and keep
`StageBreakdownRows` as the footer legend. No MotionStrip here (no genuine timeline). No fake steps —
invented architecture is never drawn as transitions.

Unchanged honest states: `display == null` → "No stage data recorded for this night."; empty segments →
"No stage breakdown for this night."; MotionStrip's own "No movement detail for this night." note.

### Card sizing

The rows stack is taller than the old strip. iOS uses `height: 524` for the timeline card; Android
`ChartCard` sizes to content — verify no fixed-height clipping, add `Metrics` constants for row height
(20dp track), row padding (8/10dp), and stack spacing.

## Non-goals (follow-ups, not this change)

- `sleepHRChart` (sleeping-HR trace with stage washes) and `sleepHeadline` (hours-of-sleep /
  restorative-sleep pair) from iOS #988 — separate port, needs `hrBuckets` plumbing on Android.
- Motion pipeline changes (imported-night motion backfill, pre-H8 backfill) — discussed and deferred.
- iOS/macOS changes: none. iOS already ships this layout; this change restores lockstep.

## Files touched

- `android/app/src/main/java/com/noop/ui/SleepScreen.kt` — new `StageTimeline`, `StageTimelineRow`,
  `StageHatchedTrack`, interval reconstruction + `displaySmoothed` port, `selectedStage` state, hero card
  body rewrite, `StageLegend` deletion, MotionStrip relocation.
- `android/app/src/main/java/com/noop/ui/Theme.kt` — new `Metrics` constants.
- Android unit tests — interval reconstruction, 90 s smoothing parity with Swift fixtures, percent math.

## Risks

- **Fragment tangles**: none by construction — one row per stage can't overlap another stage.
- **Perf**: 4 rows × N segments as composables; if a fragmented night produces hundreds of segments after
  90 s smoothing, draw the row track in a single `Canvas`/`drawWithCache` instead of per-segment `Box`es
  (follow the `Charts.kt` PERF hoist convention).
- **MotionStrip alignment**: rows have horizontal padding the old full-bleed strip didn't; MotionStrip
  must adopt the same inner insets or epochs skew against the tracks.

## Manual checks

The execution recipe's UI checks remain useful when changing this component:

1. **Real-stage night** (a night the on-device stager persisted — any recent strap night):
   - Four rows in order AWAKE · LIGHT · DEEP · REM; percents/durations agree with the night's stage totals.
   - Segments read as clean blocks (no 30 s comb); track hatching visible where the stage is absent.
   - MotionStrip sits under the rows, epochs visually aligned with segment edges (check first/last
     epoch against onset/wake); clock labels onset · midpoint · wake under it.
   - Tap DEEP: other rows' segments and % dim, DEEP row gets a stroke, insight slot shows
     "Deep tonight: …". Tap again: selection clears, hint returns, card height does NOT change.
   - Navigate to another night and back: selection cleared.
2. **Fallback night** (imported night, e.g. a Health Connect / minutes-only import): flat strip +
   `StageBreakdownRows` footer, "approx. stages (on-device)" absent, **no** MotionStrip, no dot legend.
3. **Honest empties**: night with no stage data → "No stage data recorded for this night."; real
   night with no persisted motion → MotionStrip's "No movement detail for this night." note.
4. **Accessibility**: with TalkBack, each row reads as one node — "Awake: 49 min, 10 percent of
   the night", action hint "Highlights this stage on the sleep chart".
5. **Theme**: check Classic and default palettes (row bg is a `textPrimary` alpha, must work on both).
