# NOOP macOS UI Customization Ledger

Documents intentional macOS visual/layout work on `macos-ui-experimental`, branched from
`ui-experimental` for desktop parity with the iOS redesign **without** replacing macOS navigation
or behavior.

## Branch lineage

- Base: `ui-experimental` at `8024d9a7` (`Localize live workout and search accessibility strings.`).
- Working branch: `macos-ui-experimental`.
- Upstream comparison target: Ryan’s `main` on `ryanbr/noop`.
- iOS redesign source of truth: shared `Strand/` + `Packages/StrandDesign` on `ui-experimental`.

## Non-negotiable boundaries

Same as the iOS UI ledger: no BLE, protocol, scoring, persistence, networking, HealthKit,
permissions, entitlements, or build-config changes unless strictly required for a compile and called
out here. Do not replace the macOS sidebar with an iOS tab bar. Do not remove menu-bar, window, or
keyboard behavior.

## Shared styling reused directly (no macOS fork)

Already ships on Mac via shared code from `ui-experimental`:

- Adaptive light/dark palette and liquid surfaces
- Typography, `NoopCard` / panel surfaces, borders, gradients, corner radii
- Key Metrics presentation, Trends chart framing, Sleep night-scene hero
- Workouts equal-width actions + Liquid Glass search field (macOS 26 aware)
- Live workout glanceable hierarchy, Effort a11y scale, workout-type icons
- Devices sync status card, full-width action styling patterns

## Intentional macOS differences from iOS

| Topic | macOS choice | Why |
| --- | --- | --- |
| Navigation shell | Keep `NavigationSplitView` sidebar + detail | Desktop convention; do not port bottom tabs |
| Sidebar search | System `.searchable(placement: .sidebar)` | Native Mac placement; not a hand-rolled field |
| Workout / Live Session presentation | Large `.sheet` (not `fullScreenCover`) | `fullScreenCover` is iOS-only |
| Sleep Debt tile | Stays in adaptive metric grid | Avoid stretching a phone lead-tile across an unbounded detail pane |
| Classic Today title | “Control Center” + window-toolbar Updates | Existing Mac chrome; Liquid Today is the default |
| Menu bar extra | Retained, token-aligned | No iOS twin (widgets instead) |
| Hover | `NoopCard` hover border | Pointer platform affordance |

## macOS-specific parity work (this branch)

### MAC-001 — ScreenScaffold desktop gutters + readable column

- **Files:** `Strand/Screens/ScreenScaffold.swift`
- Align horizontal/top padding with iOS (16 / 24); drop tab-bar clearance; centre content at max
  width **980** on wide detail panes.

### MAC-002 — Weekly digest compact score row on Mac

- **Files:** `Strand/Screens/WeeklyDigestView.swift`
- Enable the embedded three-gauge compact row (Trends / Today embeddings) on macOS so Week-in-review
  matches the iOS EXP-012 treatment. Full digest still uses the adaptive score grid.

### MAC-003 — Liquid Today desktop column + no tab spacer

- **Files:** `Strand/Liquid/LiquidTodayView.swift`
- Widen readable column to **920**; gate the 90pt floating-tab spacer to iOS only; extend header /
  photo Liquid Glass availability to **macOS 26** (material fallback unchanged on older macOS).

### MAC-004 — Live workout + selection glass and sheet sizing

- **Files:** `Strand/Screens/LiveWorkoutView.swift`, `Strand/Screens/WorkoutSelectionScreen.swift`,
  `Strand/Screens/LiveView.swift`, `Strand/Screens/WorkoutsView.swift`
- Extend workout-control / selection Liquid Glass to macOS 26; enlarge Mac sheet min/ideal frames;
  centre live-workout content at max width **720** inside the sheet.

### MAC-005 — Today “+” quick actions + Devices sync card always visible

- **Files:** `Strand/App/RootView.swift`, `Strand/App/NavRouter.swift`, `Strand/Screens/DevicesView.swift`,
  `Strand/Resources/Localizable.xcstrings`
- **Bug:** Liquid/classic Today header `+` called `router.requestQuickActions()`, but only the iOS
  `RootTabView` listened — on macOS the flag flipped and nothing opened.
- **Fix:** macOS shell presents `MacQuickActionsSheet` and routes picks to sidebar destinations
  (Live / Workouts / Insights / Breathe).
- **Bug:** `DeviceSyncStatusCard` rendered `EmptyView` on cold-start `.hidden`, so Devices often looked
  like it had no sync status after the indicator moved off Today.
- **Fix:** Devices always shows the card; cold start uses localized “No strap history synced yet”.
  `SyncChipState.resolve` unchanged (header chips still hide on cold start).

## Verification history

| Date | Scope | Result |
| --- | --- | --- |
| 2026-08-05 | Branch created | `macos-ui-experimental` from `ui-experimental` @ `8024d9a7` |
| 2026-08-05 | MAC-001…004 | `git diff --check` passed; i18n audit exit 0; clean `Strand` macOS Debug build succeeded; app launched locally. `ui-experimental` left at `8024d9a7`. No BLE/protocol/scoring/persistence/HealthKit/entitlement/`project.yml` changes. |
| 2026-08-05 | MAC-005 | Fixed Today `+` (macOS quick-action sheet) and Devices sync card cold-start visibility. i18n exit 0; macOS Debug build succeeded; app relaunched. |
