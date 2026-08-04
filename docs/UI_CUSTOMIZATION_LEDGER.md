# NOOP Custom UI Change Ledger

This document is the merge source of truth for the custom NOOP interface. Update it in the same
working session as every UI change. It deliberately separates the stable visual redesign from the
larger layout/UX experiments on `ui-experimental`, so either layer can be reviewed or merged later.

## Branch lineage and comparison baseline

- Upstream baseline at branch creation: `origin/main` at `3b86b6ef` (`Release 9.3.1: add to AltStore source`).
- Stable custom UI branch: `custom/noop-ui`.
- Experimental branch: `ui-experimental`, branched from `custom/noop-ui` at `18db457f`.
- Stable UI commits:
  - `b96b0661` — `Apply custom NOOP UI`
  - `18db457f` — `Refine NOOP visual design system`
- Experimental commits after `18db457f`:
  - `c0f45441` — `Develop experimental NOOP UI`
  - `bd94c5ee` — `Refine Trends and metric visuals`
- Before merging, refresh the upstream reference and repeat the audit against Ryan's then-current main.

## Non-negotiable merge boundaries

Unless a future ledger entry explicitly says otherwise, custom UI work must not modify:

- BLE communication or wearable protocols
- HealthKit behavior, permissions, capabilities, or entitlements
- scoring, calculations, algorithms, or analytics semantics
- persistence, database schemas, migrations, or data models
- networking or import behavior
- business logic, timers, async data loading, or state ownership
- bundle identifiers, signing, targets, schemes, or build configuration
- navigation destinations or the content/functionality of screens

Generated localization catalogs are not part of the redesign. The following files were intentionally
reverted and must remain excluded unless a later UI change genuinely introduces new localized copy:

- `NOOPWatch/Localizable.xcstrings`
- `NOOPWatchComplications/Localizable.xcstrings`
- `Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings`
- `Strand/Resources/Localizable.xcstrings`

## Stable custom UI layer (`custom/noop-ui`)

### Shared design system

| File | Intentional change | Merge notes |
| --- | --- | --- |
| `Packages/StrandDesign/Sources/StrandDesign/NoopVisualStyle.swift` | Added the shared visual tokens and reusable chrome surfaces for canvas, elevated/inset panels, border highlights, shadows, radii, and materials. | Core dependency for nearly every styling migration; merge first. |
| `Packages/StrandDesign/Sources/StrandDesign/Palette.swift` | Reworked the app palette toward the dark neutral custom UI with consistent semantic accent colors. | Visual tokens only. |
| `Packages/StrandDesign/Sources/StrandDesign/Typography.swift` | Standardized SF Rounded typography and restored Dynamic Type scaling for the custom overline style. | Accessibility scaling must remain intact. |
| `Packages/StrandDesign/Sources/StrandDesign/StrandCard.swift` | Routed card rendering through the shared panel surface instead of maintaining separate hard-coded card chrome. | Presentation only; card content API retained. |
| `Packages/StrandDesign/Sources/StrandDesign/Components.swift` | Migrated shared cards, chart containers, controls, and section components to design-system surfaces and typography. | Widely reused; resolve upstream conflicts carefully. |
| `Packages/StrandDesign/Sources/StrandDesign/NoopButton.swift` | Updated shared button materials, borders, and pressed appearance. | Actions and hit targets unchanged. |
| `Packages/StrandDesign/Sources/StrandDesign/StatePill.swift` | Updated state-pill chrome to shared tokens. | State semantics unchanged. |
| `Packages/StrandDesign/Sources/StrandDesign/ChartHover.swift` | Restyled chart hover/selection presentation. | Chart values and gesture behavior unchanged. |
| `Packages/StrandDesign/Sources/StrandDesign/OverviewHRChart.swift` | Migrated chart presentation details to the shared visual language. | Sampling and chart data unchanged. |
| `Packages/StrandDesign/Sources/StrandDesign/Sparkline.swift` | Updated sparkline presentation token usage. | Data path unchanged. |
| `Packages/StrandDesign/Sources/StrandDesign/NoopMotion.swift` | Adjusted presentation-related motion constants/usage for the redesign. | Keep Reduce Motion behavior; re-audit if upstream motion logic changes. |

### App-wide screens and surfaces

| File | Intentional change | Merge notes |
| --- | --- | --- |
| `Strand/App/RootView.swift` | Applied shared root/sidebar surface styling. | Navigation destinations unchanged. |
| `Strand/MenuBar/MenuBarContent.swift` | Applied shared menu-bar surface token. | Menu actions unchanged. |
| `Strand/Onboarding/OnboardingWizard.swift` | Restyled onboarding cards/backgrounds/buttons using the shared system. | Onboarding order and completion logic unchanged. |
| `Strand/Liquid/LiquidPrimitives.swift` | Replaced the liquid-slosh vessel drawing with a calmer circular progress-ring renderer. | Intentional visual renderer replacement; simulation values and tap plumbing retained. This is one of the two approved presentation differences from upstream. |
| `Strand/Liquid/LiquidSky.swift` | Retuned the liquid sky colors/gradients to match the custom palette. | Visual only. |
| `Strand/Liquid/LiquidTodayView.swift` | Migrated Today cards, headers, and dashboard chrome to the design system. | Stable commit preserves data bindings; experimental grid work is documented separately below. |
| `Strand/Liquid/LiveSessionView.swift` | Restyled live-session surfaces. | Session behavior unchanged. |
| `Strand/Screens/TodayView.swift` | Migrated classic Today presentation to shared surfaces. | Logic and routes unchanged. |
| `Strand/Screens/TrendsView.swift` | Migrated Trends presentation to shared surfaces. | Experimental cleanup is documented separately below. |
| `Strand/Screens/SleepView.swift` | Migrated Sleep cards, placeholders, and editor chrome to shared surfaces. | Sleep data/model logic unchanged. |
| `Strand/Screens/DevicesView.swift` | Migrated Devices presentation to shared cards and surfaces. | Pairing and device management logic unchanged. |
| `Strand/Screens/LiveView.swift` | Migrated Live presentation to shared surfaces. | BLE/live-session behavior unchanged. |
| `Strand/Screens/CoachView.swift` | Applied shared page/card styling. | Content and logic unchanged. |
| `Strand/Screens/CompareView.swift` | Applied shared comparison-card styling. | Comparison calculations unchanged. |
| `Strand/Screens/CoupledView.swift` | Applied shared coupled-metric styling. | Data bindings unchanged. |
| `Strand/Screens/InsightsHubView.swift` | Applied shared page/card styling. | Navigation unchanged. |
| `Strand/Screens/InsightsView.swift` | Applied shared insight-card styling. | Journal behavior unchanged. |
| `Strand/Screens/MetricExplorerView.swift` | Applied shared metric/chart styling. | Metric selection and data unchanged. |
| `Strand/Screens/TrendsReportView.swift` | Applied shared report-card styling. | Report contents unchanged. |
| `Strand/Screens/WeeklyDigestView.swift` | Applied shared weekly-digest styling. | Digest calculations unchanged. |
| `Strand/Screens/UpdatesInboxView.swift` | Applied shared page/card styling. | Update actions unchanged. |
| `Strand/Screens/AppleWatchSetupView.swift` | Applied shared setup-card styling. | Watch setup behavior unchanged. |
| `Strand/Screens/EditableLayoutList.swift` | Applied shared editor-row styling. | Reordering behavior unchanged. |
| `Strand/Screens/HRVSnapshotView.swift` | Applied shared snapshot styling. | Measurement behavior unchanged. |
| `Strand/Screens/HydrationView.swift` | Applied shared hydration-card styling. | Logging behavior unchanged. |
| `Strand/Screens/ManualWorkoutSheet.swift` | Applied shared sheet styling. | Workout creation unchanged. |
| `Strand/Screens/NotificationSettingsView.swift` | Applied shared settings styling. | Notification settings behavior unchanged. |
| `Strand/Screens/ScoringGuideView.swift` | Applied shared guide styling. | Scoring descriptions/logic unchanged. |
| `StrandiOS/App/RootTabView.swift` | Stable layer restyled the iPhone shell and quick-action surfaces. | Experimental native-tab replacement supersedes the custom bar; see below. |

### Approved stable differences from upstream

1. Updated page and section spacing remains intentional.
2. The progress-ring renderer remains intentional instead of restoring the liquid-slosh renderer.

The earlier audit confirmed no intended stable changes to business logic, BLE, protocol, scoring,
persistence, networking, navigation flow, data models, entitlements, or build configuration.

## Experimental UI/UX layer (`ui-experimental`)

These entries describe the current working-tree changes after `18db457f`. They are ordered by user-visible
feature rather than by file so they can be reviewed and ported independently.

### EXP-001 — Two-column Key Metrics grid

- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Changed the Home/Today Key Metrics grid from three columns to two.
- Increased card minimum height, corner radius, padding, internal spacing, progress-bar height, title size,
  and value hierarchy.
- Added subtle SF Symbols for Recovery, Strain, Rest, HRV, Resting HR, Blood Oxygen, Respiratory, Steps,
  Weight, and Calories.
- Units/suffixes now use the same 24-point rounded number style as the main value.
- Percentage values have no separating space (`82%`); textual units retain one (`48 ms`, `62 bpm`).
- Preserved metric ordering, editor preferences, detailed-card mode, sparks, routes, and data bindings.
- **Type:** intentional layout and presentation change; no data or calculation impact.

### EXP-002 — Move sync status from Today header to Devices

- **Files:** `Strand/Liquid/LiquidTodayView.swift`, `Strand/Screens/TodayView.swift`,
  `Strand/Screens/DevicesView.swift`
- Removed the small sync-status circles/chips from both Liquid Today and classic Today headers.
- Retained the existing shared `SyncChipState` resolver.
- Added a larger Devices-screen status card using the same state and accessibility descriptions.
- The card reports syncing progress, last-sync age, experimental live state, or hides on cold start exactly
  as the prior header indicator did.
- **Type:** intentional presentation/location change; sync behavior and BLE logic unchanged.

### EXP-003 — Shared time-range selector redesign

- **Files:** `Packages/StrandDesign/Sources/StrandDesign/Components.swift`,
  `Strand/Screens/TrendsView.swift`
- Restyled the existing shared `SegmentedPillControl` with a neutral inset rounded track and a raised,
  bordered selected segment.
- Added the opt-in `fillsAvailableWidth` parameter; existing callers retain their previous sizing.
- Trends enables full-width mode for `W / M / 3M / 6M / 1Y / All`.
- Removed the redundant range-summary text that previously occupied the selector's right side.
- Dynamic Type adaptation and selection bindings remain intact.
- **Type:** presentation plus intentional Trends layout use; filtering logic unchanged.

### EXP-004 — Neutralize Trends cards

- **Files:** `Strand/Screens/TrendsView.swift`
- Removed the green-tinted surface/glow from Week in Review, Charge charts, HRV/RHR trend cards, and the
  history strip while preserving semantic colors inside the actual data graphics.
- Removed the redundant `WEEK IN REVIEW` subtitle beneath `This week`.
- Kept card contents, order, chart data, and interactions unchanged.
- **Type:** visual cleanup only.

### EXP-005 — Sleep header and label cleanup

- **Files:** `Strand/Screens/SleepView.swift`
- Removed small right-side explanatory labels from Sleep Performance, Night Detail, Sleep-debt Ledger,
  Stages vs Typical, Asleep Duration, and Sleep Marks section headers.
- Redesigned the navigated-night date beside `Sleep / Last night` as a compact neutral capsule with
  semibold caption typography and intentional bottom alignment.
- Kept previous/next-night buttons, date value, selected night, accessibility, and data unchanged.
- **Type:** visual cleanup and localized header layout only.

### EXP-006 — Native Apple tab bar / Liquid Glass

- **Files:** `StrandiOS/App/RootTabView.swift`
- Confirmed a native SwiftUI `TabView` already existed beneath the custom floating bar.
- Removed `FloatingTabBar`, its custom buttons, background, blur/material, gradients, borders, shadows,
  active-tab pill, custom `.glassEffect()` helper, tab-bar hiding, and the global `UITabBarAppearance`
  override.
- Restored the system-rendered tab bar for Today, Trends, Sleep, and More.
- iOS 26+ receives Apple's native Liquid Glass automatically; older supported iOS versions receive the
  standard native system tab bar from the same `TabView`.
- Preserved the selection state, per-tab `NavigationPath`, tab swipe, routes, screen state, and native
  reselection forwarding to the existing refresh / pop-to-root / scroll-to-top behavior.
- More uses the visible custom-bar icon (`ellipsis`) in the restored native item.
- **Type:** intentional navigation-chrome implementation change; destinations and screen content unchanged.

### EXP-007 — Native Liquid Glass Home header buttons

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Replaced the custom circular fills, borders, and press-only styling on the Home header's Profile,
  Quick Actions, Battery/Devices, and Customize Today buttons with Apple's native `.glass` button style.
- The profile control uses the exact same native `.glass` style, circular border shape, and small control
  size as the other three buttons. Its photo is overlaid across the button's measured circular bounds so
  it fills the face without changing the control's outer size or hit area. Apple's interactive
  `.glassEffect` is then applied as the final layer over the composed photo control so the edge-to-edge
  image cannot conceal the system glass refraction and highlight.
- iOS 26+ uses interactive system Liquid Glass with a circular button border shape; older supported iOS
  versions retain the same circular geometry using native `ultraThinMaterial` and the existing press motion.
- Preserved all four actions, SF Symbols/avatar content, battery state rendering, accessibility labels,
  routes, and hit behavior.
- **Type:** visual button-chrome change only; no app logic or navigation destination changes.

### EXP-008 — Refined Sleep Performance night scene

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/SleepView.swift`
- Replaced only the Sleep Performance hero's generic time-of-day decoration with a deterministic,
  card-local night scene: deep shared-token navy/black gradients, a restrained star Canvas, a single
  intentional `moon.fill` crescent, and faint central blue atmosphere.
- Added a subtle card-local moonlight shadow to the existing progress ring without changing its value,
  animation, renderer, tap behavior, or progress fraction.
- Integrated the existing score-state word into a low-contrast capsule and retained the existing source
  badge, score typography, labels, content order, spacing system, radius, border, and elevation language.
- Preserved sleep scoring, model construction, data loading, bindings, navigation, calculations,
  accessibility value, and all interactions.
- **Type:** decorative visual redesign only.

### EXP-009 — Trends weekly-summary cleanup

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/WeeklyDigestView.swift`
- Removed the remaining Charge/green tint from the Week in Review header card by using the shared neutral
  `NoopPanelSurface` with the same radius and elevation.
- Hid the scale caption beneath only the embedded Effort and Rest gauges while retaining the Charge
  caption. The invisible caption views retain their original layout space, so card height, gauge alignment,
  spacing, and the three-column geometry remain unchanged.
- Preserved digest values, gauge fractions, animations, week navigation, comparison chips, calculations,
  bindings, interactions, and card-level accessibility summaries.
- **Type:** visual cleanup only.

### EXP-010 — Flat Home Key Metrics progress fills

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidPrimitives.swift`, `Strand/Liquid/LiquidTodayView.swift`
- Added a default-on `showsHighlight` presentation option to the shared `LiquidTube` renderer and disabled
  it only for the Home Key Metrics tiles.
- Removed the one-point white reflection strip from the top of those filled bars while preserving each
  metric's existing tint gradient and subtle depth.
- The dark track, bar height, capsule radius, spacing, fill edge, animation mode, fractions, calculations,
  bindings, and every non-Key-Metrics `LiquidTube` caller remain unchanged.
- **Type:** Home Key Metrics visual cleanup only.

### EXP-011 — Clean gradient Key Metrics progress fills

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidPrimitives.swift`, `Strand/Liquid/LiquidTodayView.swift`
- Added a default-off `usesCleanFill` renderer mode and enabled it only for Home Key Metrics.
- Replaced those fills with a restrained horizontal dark-to-base gradient derived from each metric's
  existing tint, keeping green, blue, orange, cyan, and other metric identities unchanged.
- Suppressed all internal flecks/particles and their decorative animation in clean-fill mode; the prior
  top-reflection opt-out remains enabled.
- Preserved the dark track, height, capsule radius, dimensions, spacing, fill fraction, calculations,
  bindings, layout, and existing progress update behavior. Other `LiquidTube` callers retain their defaults.
- **Type:** Home Key Metrics visual cleanup only.

### EXP-012 — Compact Trends weekly summary

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/TrendsView.swift`, `Strand/Screens/WeeklyDigestView.swift`
- Removed the standalone Week in Review date surface only from the Trends embedding and moved its
  localized date range plus days-with-data count beneath the centered selected-week title.
- Kept both week-navigation arrows and the existing selected-week digest source, offset binding,
  range boundaries, button actions, empty-week handling, and accessibility descriptions.
- Vertically centered the visible Charge, Effort, and Rest metric groups independently within the
  compact shared row. Removed the invisible caption and comparison placeholders that made Effort and
  Rest appear top-heavy, without increasing the card height. Preserved the three columns, dividers,
  gauges, values, animations, calculations, and bindings.
- The Today embedding and full Week in Review screen retain their existing header by default.
- **Type:** Intentional Trends layout cleanup only.

### EXP-013 — Live heart-rate card refinement

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Consolidated the card header into one balanced row with the metric heading on the left and the live
  heart icon, BPM value, and unit on the right. The upstream state-dependent subtitle remains directly
  beneath it for live, five-minute fallback, waiting-for-strap, and disconnected states.
- Replaced the live dot with an SF Symbol heart driven by the same incoming `live.heartRate` change event,
  without adding a timer or continuous animation loop.
- Added a static, clipped Canvas grid behind the existing trace using the shared hairline token.
- Preserved the BPM source, sample buffer, update timing, chart renderer, smoothing/scaling behavior,
  trace color, values, animations, min/average/max statistics, Full day route, card interaction, and BLE.
- **Type:** Live heart-rate card presentation only.

### EXP-014 — Full-width metrics action

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Added a reusable `LiquidFullWidthNavigationAction` presentation using the shared panel surface,
  button geometry tokens, typography, mint accent, trailing chevron, and accessible control height.
- Replaced the standalone Show all metrics text with the full-width action surface.
- Applied the same reusable full-width action surface to Full day inside the Heart Rate card. Its existing
  whole-card `NavigationLink` remains, so the visible action and the surrounding card open the same route.
- Preserved both `NavigationLink` values, the existing whole-card Heart Rate interaction, Key Metrics
  layout, chart layout/data, calculations, bindings, and BLE behavior.
- **Type:** Dashboard action presentation only.

### EXP-015 — PR review presentation restorations

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidTodayView.swift`, `Strand/Screens/TrendsView.swift`,
  `Strand/Screens/WeeklyDigestView.swift`, `Strand/Resources/Localizable.xcstrings`
- Localized the compact Trends days-with-data text and matching accessibility description in English,
  German, Spanish, and French using the existing string-catalog workflow.
- Restored the upstream Live HR subtitle states and conditions while retaining the redesigned header,
  heart pulse, grid, chart, data sources, and update timing.
- Restored embedded weekly-gauge scale captions for populated Effort and Rest gauges, including Effort's
  existing selected-scale denominator, without changing scores, calculations, or gauge behavior.
- Restored the visible Full day action with the same shared full-width component used by Show all metrics;
  its route and the whole-card navigation behavior are unchanged.
- The Today sync indicator was deliberately left unchanged for separate review.
- **Type:** Localization and presentation-information restoration only.

### EXP-016 — Live workout glanceable hierarchy

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/LiveWorkoutView.swift`
- Rebuilt the live-workout presentation around two dominant readings: elapsed time and live heart rate.
  The recording state is now a compact status capsule, while the selected HR zone sits beside the live
  reading and the complete five-zone rail plus its exact bounds remain directly below.
- Reframed the existing Effort gauge as a compact supporting card and consolidated Avg, Peak, and Effort
  into one evenly divided summary surface to reduce competing card chrome.
- Consolidated optional speed, cadence, and power values into one sensor panel while preserving the
  independently observing `SensorRowIfPresent` leaf and its conditional fields.
- Preserved the workout timer source, live BPM and zone derivation, effort scale and calculation, sensor
  values and units, realtime-stream lifecycle, keep-awake behavior, active-workout dismissal, End action,
  destructive confirmation, save behavior, and every existing state dependency.
- **Type:** Experimental live-workout layout and presentation redesign only.

### EXP-017 — Home-style live Effort vessel

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/LiveWorkoutView.swift`
- Replaced only the live-workout Effort circle renderer with the same shared `LiquidVessel` visual used
  by the Home Charge, Effort, and Rest hero scores, including its motion and Reduce Motion behavior.
- Preserved `ActiveWorkout.liveStrain` as the source, the selected 0–100/0–21 display conversion, exact
  fill fraction, live updates, formatted value, scale denominator, card placement, and accessibility value.
- Restored the original dynamic Effort intensity label (`LIGHT` through `ALL-OUT`) using the exact shared
  `StrainGauge` thresholds and translations, placing it beneath `EFFORT BUILDING`; the scale denominator
  remains inside the vessel beneath the live number.
- **Type:** Effort gauge rendering only; no workout behavior or calculation changes.

### EXP-018 — Workouts control layout

- **Date:** 2026-08-04
- **Files:** `Strand/Screens/WorkoutsView.swift`
- Placed Start workout and Add workout side by side as equal-width actions spanning the standard card
  width, with the existing day-range selector on its own full-width row below.
- Made the existing Sport and Source filter menus equal-width controls that together span that same card
  width. Search and clear-filter behavior remain available immediately below the selectors.
- Preserved every action, sheet, live-workout destination, range/filter binding, caption, and data path.
- **Type:** Experimental Workouts control layout only.

### EXP-019 — Inline Live HR destination affordance

- **Date:** 2026-08-04
- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Removed the full-width Full day button from the Today live-heart-rate card and placed a compact
  heart-rate-coloured chevron directly beside the localized Beats per minute heading instead.
- The heading group has higher layout priority, a fixed-size chevron, and controlled text scaling so the
  arrow stays attached to longer localized text without colliding with the changing BPM value.
- Preserved the whole-card `TabRoute.fullDayChart` navigation link, destination, live subtitle states,
  chart, statistics, sampling, animation, and accessibility hint.
- **Type:** Live HR affordance presentation only; destination and behavior unchanged.

## Verification history

| Date | Scope | Result |
| --- | --- | --- |
| 2026-08-03 | Stable redesign audit against Ryan main | `git diff --check` passed; generated catalogs reverted; no business logic, BLE, protocol, scoring, persistence, networking, navigation-flow, data-model, entitlement, or build-configuration changes retained. |
| 2026-08-04 | Sleep date badge | Debug device build succeeded; installed and launched on Liam's iPhone using `NOOPiOS`, `com.liammazuz.noop`, team `P2874N8GRQ`. |
| 2026-08-04 | Key Metric typography and percentage spacing | Incremental Debug device builds succeeded; installed and launched on the connected iPhone. Existing unrelated compiler warnings remained. |
| 2026-08-04 | Native system tab bar | Debug physical-device build, signing, installation, and launch succeeded. Automated mirrored interaction was unavailable because the phone was in use; source verification confirmed all custom bar rendering paths were removed. |
| 2026-08-04 | Native Liquid Glass Home header buttons | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone with `com.liammazuz.noop` and team `P2874N8GRQ`. Existing unrelated compiler warnings remained. |
| 2026-08-04 | Refined Sleep Performance night scene | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone. Source audit confirmed the score source, progress fraction, animation, labels, source badge, accessibility value, and interactions were unchanged. |
| 2026-08-04 | Trends weekly-summary cleanup | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone. `git diff --check` passed; existing unrelated compiler warnings remained. |
| 2026-08-04 | Flat Home Key Metrics progress fills | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone. `git diff --check` passed; existing unrelated compiler warnings remained. |
| 2026-08-04 | Clean gradient Key Metrics progress fills | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone. `git diff --check` passed; existing unrelated compiler warnings remained. |
| 2026-08-04 | Compact Trends weekly summary | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone using `com.liammazuz.noop`. Source verification confirmed the date range and day count use the selected digest and the existing week-navigation actions remain unchanged; `git diff --check` passed. Existing unrelated compiler warnings remained. |
| 2026-08-04 | Pre-PR audit against Ryan main `3b86b6ef` | Branch is 4 commits ahead and 0 behind. Full 41-file diff audited; no BLE, protocol, scoring, sleep-calculation, persistence, networking, HealthKit, data-model, permission, entitlement, or build-configuration changes found. Changes are limited to presentation, approved layout, sync-status placement, and native tab-bar chrome/reselection forwarding. |
| 2026-08-04 | Live heart-rate card refinement | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone using `com.liammazuz.noop`. Source verification confirmed the pulse reuses incoming heart-rate changes and the static grid adds no timer or continuous redraw loop; `git diff --check` passed. Existing unrelated compiler warnings remained. |
| 2026-08-04 | Full-width metrics action | `NOOPiOS` Debug physical-device build succeeded; installed and launched on the connected iPhone using `com.liammazuz.noop`. Show all metrics uses the reusable full-width surface; the Heart Rate card retains its whole-card route with no separate Full day control. `git diff --check` passed. Existing unrelated compiler warnings remained. |
| 2026-08-04 | PR review presentation restorations | i18n CI audit and `git diff --check` passed. A clean `NOOPiOS` Debug physical-device build succeeded, including `DevicesView`; the signed `com.liammazuz.noop` build was installed and launched on the connected iPhone. Source-path verification confirmed the upstream Live HR subtitle branches, weekly gauge captions, selected-week localization inputs, and unchanged Full day destination. |
| 2026-08-04 | Live workout glanceable hierarchy | i18n CI audit and `git diff --check` passed. The `NOOPiOS` Debug physical-device build succeeded and the signed `com.liammazuz.noop` app was installed and launched on the connected iPhone. Diff verification confirmed all workout data sources, calculations, lifecycle hooks, sensor isolation, actions, and confirmation behavior remain unchanged. Existing unrelated compiler warnings remained. |

## Required workflow for every future custom UI change

1. Add or update an `EXP-###` entry in this file during the same work session.
2. Record every touched source file, the visible outcome, and whether layout or navigation chrome changed.
3. State which bindings, actions, routes, accessibility behavior, and data semantics were deliberately preserved.
4. Record any shared-design-system API added or changed and list all opt-in callers.
5. Keep generated files and unrelated workspace changes out of the change.
6. Run `git diff --check` and an appropriate build.
7. When installed on a device, record the scheme, bundle ID, signing team, and result in Verification History.
8. Before a commit, compare the complete diff against the latest upstream main and explicitly audit the
   protected categories listed under Non-negotiable merge boundaries.
9. Do not commit or push unless explicitly requested.

### Template for the next entry

```markdown
### EXP-### — Short feature name

- **Date:** YYYY-MM-DD
- **Files:** `path/to/file.swift`
- **Request:** What the user asked to change.
- **Implementation:** Exact visual/layout implementation.
- **Preserved:** Bindings, actions, navigation, accessibility, data, and logic intentionally unchanged.
- **Compatibility:** Availability behavior or older-iOS fallback, if applicable.
- **Verification:** `git diff --check`, build target/result, and physical-device result.
- **Type:** visual only / intentional layout / navigation chrome / other approved scope.
```

## Pre-merge checklist

- [ ] Fetch Ryan's latest main without merging it.
- [ ] Compare both committed and uncommitted changes against that exact upstream commit.
- [ ] Confirm this ledger lists every changed source file.
- [ ] Confirm generated localization catalogs are clean.
- [ ] Confirm no generated project/build artifacts are tracked.
- [ ] Run `git diff --check`.
- [ ] Build the `NOOPiOS` Debug scheme.
- [ ] Re-run the protected-category audit.
- [ ] Review stable and experimental changes separately.
- [ ] Decide which experimental entries are approved for the merge.
- [ ] Commit in small, ledger-aligned groups only after approval.
