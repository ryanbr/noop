# NOOP v5 "Strand" — Umbrella Design Spec (IA · Design Language · Positioning)

**Date:** 2026-06-19 · **Status:** Proposed — integration glue for the v5 pillar set
**Scope:** This is the **umbrella** spec. It does *not* design a feature. It designs (1) the information
architecture that holds the seven v5 pillars without bloat, (2) the design-language guardrails every
pillar must obey + one fully-resolved example screen, (3) the cross-cutting non-clinical / legal posture
and a single consolidated in-app disclaimer surface, (4) the v5 positioning + marketing one-liner, and
(5) versioning / lockstep + a phased ship plan.

**The problem we are solving.** The current ship (v4.9.1) has **23 flat sidebar entries on macOS**
(`Strand/App/RootView.swift` `NavItem`), a **3-tab + FAB + 4-section "More" list on iOS**
(`StrandiOS/App/RootTabView.swift`), and a **7-group drawer + 3-tab bar on Android**
(`android/.../ui/AppRoot.kt`). The subreddit's exact criticism was *"features spread across navigations
without clear separation."* Layering seven more pillars on top of that flat list would make it
unusable. v5's job is to **collapse the surface area into a small number of honest hubs** without moving
the data model and without a from-scratch redesign — every screen that exists today survives, it just
gets a coherent home.

## The seven v5 pillars (referenced specs)

This umbrella is the integration layer for the seven pillar specs. Each owns its own engine/algorithm;
this doc only decides **where each lives** and **how they share chrome**.

| # | Pillar | Spec file | Lives in |
|---|--------|-----------|----------|
| 1 | Fitness Age / readiness + multi-source bands | `docs/superpowers/specs/2026-06-15-multi-source-bands-and-age-engine-design.md` | **Health** hub + **Devices** |
| 2 | Mind — mood check-in + correlations | `docs/superpowers/specs/2026-06-12-noop-mind-mental-health-design.md` | **Insights** hub |
| 3 | Third-party file imports (nutrition / GPX / TCX / FIT) | `docs/superpowers/specs/2026-06-12-noop-third-party-imports-design.md` | **Devices & Sources** |
| 4 | GPS workout activities | `docs/superpowers/specs/2026-06-10-gps-workout-activities-design.md` | **Today** quick-action → Workouts |
| 5 | Skin-temp trend / illness-watch cards | *sibling v5 spec (this batch): `2026-06-19-skin-temp-*-design.md`* | **Health** hub |
| 6 | Breathe / HRV haptic biofeedback (the "act on the body" pillar) | *sibling v5 spec: `2026-06-19-breathe-biofeedback-*-design.md`* | **Today** quick-action + **Insights** outcome cards |
| 7 | Coach (bring-your-own-key, opt-in) | *sibling v5 spec: `2026-06-19-coach-*-design.md`* | **Insights** hub (single entry) |

> The three "sibling v5 spec" filenames are the other agents' outputs in this same 2026-06-19 batch;
> when those land, fix the names here. The IA below is the contract they build into.

---

## 1. Goal & differentiation (why only NOOP)

**Goal.** Make NOOP feel like *one product with five places to go*, not twenty-three features in a list.
A new user should be able to name where everything is after thirty seconds. A returning power user should
reach any feature in ≤ 2 taps.

**Why only NOOP can frame it this way.** Every competitor's IA is organised around *scores their cloud
computed and shipped you*. NOOP's IA can be organised around the **signal chain it owns end to end**:
raw signals → on-device computation → an action it can take on your body (the haptic motor) → fusion of
multiple devices, all offline. That is a structural story no cloud-scored app can tell, and the navigation
should *read* that story: **Today** (what's true now) · **Insights** (what your own numbers mean,
including the coach and the breathe-outcomes) · **Health** (your body's longer arc) · **Devices &
Sources** (where signals come from + what you imported) · **Settings**. Five destinations. The "only one
that can breathe you back down" pillar (HRV haptic biofeedback) is the literal proof that NOOP *acts*,
not just *reports* — it earns a permanent quick-action, not a buried screen.

---

## 2. The v5 information architecture

### 2.1 The five top-level destinations

Collapse 23 sidebar items into **five hubs**. Nothing is deleted — secondary screens become **sections
within a hub** or **drill-ins from it**, exactly the way `HealthView` already composes `SyncStatusSection`
/ `HeartRateSection` / `FitnessAgeSection` / `VitalitySection` / `RecoveryContributorsSection` /
`VitalsSection` into one scroll.

| Hub | Purpose (one honest line) | Absorbs today's items |
|-----|---------------------------|------------------------|
| **Today** | What's true right now, for the selected day. | Today, Live (as quick-action), Stress card, Workouts entry, Smart Alarm card |
| **Insights** | What your own numbers mean — patterns, coaching, mood, breathe outcomes. | Insights, Intelligence, Coach, Compare, Mind (new), Breathe-outcomes, Explore (as "Browse metrics") |
| **Health** | Your body's longer arc — heart, sleep, recovery contributors, fitness age, skin temp, vitals. | Health, Sleep, Trends, Fitness Age, Vitality, Skin-temp (new), HRV snapshot |
| **Devices & Sources** | Where your signals come from, and what you've imported. | Devices, Data Sources, Apple Health, Mi Band, third-party imports (new), Shortcuts export |
| **Settings** | App, automations, notifications, appearance, the disclaimer, support. | Settings, Automations, Notifications, Support, Smart-alarm setup, About/Legal |

**Breathe and Live are not hubs — they are actions.** They live on the centre FAB / quick-action sheet
(already built on all three platforms) because they are "do it now" verbs, not places. This is consistent
with how `RootTabView`/`AppRoot` already treat Live and Breathe.

### 2.2 The shell per platform (grounded in what exists)

The shell idiom per platform **does not change** — we re-point the existing shells at five destinations.

- **iOS (`RootTabView`)** — five-slot bottom bar, the centre gold FAB unchanged:
  `Today · Insights · [FAB] · Health · Sources`. **Settings moves off the bar** into a top-trailing
  gear on each hub (and stays reachable from the FAB sheet's overflow). The current "More" tab is
  **retired** — its four sections (`Insights` / `Body` / `Data` / `App`) map onto the four content hubs,
  so nothing is orphaned. The FAB quick actions stay `Live HR · Start workout · Log journal · Breathe`.
- **macOS (`RootView` sidebar)** — the sidebar keeps its native form but the flat `NavItem` list is
  **regrouped under five headers** matching the hubs, with the long tail demoted to in-hub sections
  (a `List(.sidebar)` with `Section` headers — five groups, ~3–5 rows each, instead of 23 peers). The
  `NavRouter` cross-screen jump (`requestedDestination`) extends to address *hub + section anchor* so
  "Manage devices" still deep-links.
- **Android (`AppRoot`)** — the `drawerGroups` collapse from seven groups to five; the bottom
  `bottomTabs` become `Today · Insights · Health · Sources` + the existing centre FAB. The `ModalBottomSheet`
  "More" and drawer both render the same five-group list (one source of truth — keep the single
  `drawerGroups` list and reuse it for both, as today).

### 2.3 The hub pattern (the anti-bloat rule)

Every hub is **one vertical scroll of `SectionHeader` + cards**, never a sub-tab-bar, never a nested
navigation forest. A hub has at most **5 sections**; a section that grows past one card-row drills into a
**detail screen** (push), it does not add a sixth section. This is the single rule that keeps seven new
pillars from re-bloating the IA:

> **Rule of 5 / 5 / 2.** ≤ 5 hubs · ≤ 5 sections per hub · ≤ 2 taps to any feature. A new pillar must name
> which hub and which section it joins (or replace an existing one). If it cannot, it does not ship in v5.

Section ordering inside a hub is **importance-first, then recency** — the same logic `TodayView` already
uses (hero → key metrics → workouts → sources).

### 2.4 Where each pillar's surfaces connect (the wiring)

- **Breathe / biofeedback (act-on-body):** entry = Today FAB → Breathe session screen. Its *outcome*
  (HRV before/after, the existing v2.1.0 "Breathe outcomes") surfaces as an **`InsightCard` in Insights**,
  and a Today summary chip after a session. One feature, two honest touch-points, zero new nav items.
- **Insights correlations (Mind + behaviour):** all correlation/mood content is **sections of the Insights
  hub**, not separate destinations. Mind's daily mood check-in is a single card at the top of Insights
  with a drill-in for history; its correlations render as `InsightCard`s below.
- **Skin-temp cards:** a **section of Health** ("Skin temperature"), with the illness-watch banner using
  the existing `HealthAlertBanner` pattern. Never its own destination.
- **Health Records / vitals:** stay the Health hub's vitals section + per-vital drill-in (Android already
  has `vital_detail/{key}`; mirror the deep-link on macOS/iOS).
- **Coach:** **one** entry in Insights ("Coach"), opt-in, bring-your-own-key. Never auto-runs, never a tab.
- **Devices + imports + Apple Health:** all consolidate under **Devices & Sources**, split into two
  sections — "Devices" (live bands, pairing, fitness-age source) and "Imports & sync" (file imports,
  Apple Health, Mi Band, Shortcuts export).

---

## 3. Design-language guardrails (+ one fully-resolved screen)

v5 is **not** a re-skin. The Titanium & Gold system + the Warm-Paper light theme stay verbatim. The
umbrella's job is to make the guardrails explicit so seven pillars rendered by different hands look like
one app. These are **enforced**, not suggestions.

### 3.1 Tokens only (the CSS-var-equivalent contract)

- **Colour:** only `StrandPalette.*` (`Packages/StrandDesign/.../Palette.swift`) and `Palette.*` on
  Android. **Never a raw hex in a screen.** The whole point of the dynamic `Color(light:dark:)` system
  (light-theme spec) is that 1,697 Swift call-sites + ~1,740 Kotlin call-sites resolve per scheme with
  zero churn — a hardcoded hex breaks light mode silently.
- **Per-domain colour:** name a `DomainTheme` (`.charge/.effort/.rest/.stress`) and read
  `.color/.deep/.bright/.glow/.gradient` — never assemble a one-off gradient.
- **Type:** only `StrandFont.*` (`display/title1/title2/headline/body/subhead/caption/footnote/overline`
  + `number()/bodyNumber/captionNumber`). Helvetica + rounded numerics; no ad-hoc `.font(.system(size:))`
  except inside locked components.
- **Spacing:** only `NoopMetrics.*` — `cardPadding 16 · gap 12 · sectionGap 28 · screenPadding 24 ·
  tileHeight 108 · chartHeight 220 · tabBarClearance 76`. No magic numbers between cards/sections.
- **Motion:** only `StrandMotion.*` — `interactive` (taps), `gentle`, `hero`, `breathe`, the calm global
  easing `cubic-bezier(0.22,1,0.36,1)` for tab/section crossfades (~240 ms). Honour Reduce Motion (the
  `PulseDot` / `breathe` already do).
- **Z-order / elevation:** dark = flat (hairline + hue carry the edge); light = raised-by-shadow. This is
  owned by `FrostedCardSurface` — never hand-roll a card shadow.

### 3.2 Components only (no ad-hoc cards)

Every pillar composes from the **locked component set** in `Packages/StrandDesign` and its Kotlin twin —
do **not** invent a card:

- `NoopCard` / `StrandCard` (the one surface, optional domain `tint`)
- `StatTile` (uniform `tileHeight` metric tile, optional sparkline + `TrendChip`)
- `ChartCard` + `ChartFooter` (header + fixed chart body + footer)
- `InsightCard` (coaching/synthesis card, hue wash + border)
- `SectionHeader` (overline + title + optional trailing)
- `SegmentedPillControl` (the one range control)
- `SourceBadge`, `ScoreStatePill` (Solid/Building/Calibrating/Live), `StatePill`
- Buttons: `.noopPrimary` (gold CTA) · `.noopSecondary` · `.noopGhost`
- Gauges/charts: `RecoveryRing`, `StrainGauge`, `BevelGauge`, `Sparkline`, `TrendChart`, `Hypnogram`,
  `OverviewHRChart`, `YearHeatStrip`, `ScenicHeroBackground`

### 3.3 Honesty & accessibility (non-negotiable, design-level)

- **Equal-height tiles.** All tiles in a grid are `NoopMetrics.tileHeight` (108) — never ragged. (This is
  the Strand analogue of the workspace "equal-height cards" rule.)
- **Nil-honest.** A score that can't compute shows **Calibrating / Building** via `ScoreStatePill`, never a
  faked number. A 5/MG-thin day reads truthfully. No empty card where data exists — fall back to all-history.
- **No `alert()` for status.** Status uses pills/banners/toasts in the house style, not raw system alerts.
- **ARIA-equivalent.** Icon-only buttons carry `accessibilityLabel`; decorative gauges/sparklines/heroes are
  `accessibilityHidden`; tiles combine to **one** VoiceOver stop (`StatTile` already does). ≥ 44 pt touch
  targets on iOS (`SegmentedPillControl` already enforces).
- **No vibe-coded screens.** No ALL-CAPS body text, no 2×N stat-tile soup with no hierarchy, no inline
  hex, no new gradient — if it isn't in §3.1/§3.2 it doesn't ship. (Mirrors the maintainer's Convoy
  design-discipline rule.)
- **Copy is plain and honest.** USD never GBP. Never claim to *diagnose/treat/screen*. Never name any AI/LLM
  anywhere in shipped copy **except** the opt-in bring-your-own-key Coach (and there, only "bring your own
  key", never the model). NOOP is the WHOOP *companion* — never implies affiliation.

### 3.4 The fully-resolved example screen — **Insights hub (iPhone)**

A worked screen so every pillar author has a concrete target. This is the busiest new hub (it absorbs the
most pillars), so resolving it proves the IA holds.

```
┌─────────────────────────────────────────────┐
│  ◉ NOOP   Insights                       ⚙︎  │  ← top bar: BrandMark + StrandFont.title2,
│                                              │     trailing gear → Settings (no More tab)
├─────────────────────────────────────────────┤
│  TODAY'S SYNTHESIS                  · Solid  │  ← SectionHeader overline + ScoreStatePill
│  ┌─────────────────────────────────────────┐│
│  │ InsightCard (tint = charge/gold)        ││  ← one InsightCard, hue wash + .22 border
│  │ "Charge is up 9 pts. Your HRV rose      ││     copy from IntelligenceEngine, plain English,
│  │  with two earlier nights this week."    ││     NEVER a diagnosis, NEVER names an LLM
│  └─────────────────────────────────────────┘│
│                                              │  ← sectionGap (28)
│  MIND                          Log today's →  │  ← Mind pillar, section 2
│  ┌─────────────────────────────────────────┐│
│  │ NoopCard: 5-face mood row (tap to log)  ││  ← single card; history is a drill-in (push),
│  │ last 7 days as faint dots underneath    ││     NOT a second section. Non-clinical framing
│  └─────────────────────────────────────────┘│     line: "a personal journal, not an assessment"
│                                              │
│  PATTERNS                         This month  │  ← SegmentedPillControl (range) as trailing
│  ┌──────────────┐  ┌──────────────┐          │
│  │ InsightCard  │  │ InsightCard  │          │  ← correlation cards (CorrelationEngine),
│  │ "Late caffeine│  │ "Breathe →   │          │     equal height, 2-up grid, tinted by domain.
│  │  → −6 Rest"   │  │  +12ms HRV"  │          │     The Breathe card is the act-on-body proof.
│  └──────────────┘  └──────────────┘          │
│                                              │
│  COACH                              Optional  │  ← single entry, opt-in
│  ┌─────────────────────────────────────────┐│
│  │ NoopCard: "Ask the Coach about your week"││  ← bring-your-own-key; if no key, a ghost CTA
│  │ [ Set up Coach ]  ·  brings your own key ││     "Set up Coach". No LLM named. No auto-run.
│  └─────────────────────────────────────────┘│
│                                              │
│  BROWSE METRICS                           →   │  ← Explore demoted to a row, not a tab
│  ┌─────────────────────────────────────────┐│
│  │ NoopCard row → MetricExplorerView (push) ││
│  └─────────────────────────────────────────┘│
│         (last card clears tabBarClearance 76) │
├─────────────────────────────────────────────┤
│  Today    Insights    ⊕    Health   Sources  │  ← 5-slot bar, gold FAB centre
└─────────────────────────────────────────────┘
```

**Resolved details (the bar every pillar meets):** five sections exactly (Rule of 5); each is
`SectionHeader` + one card or one equal-height grid; ranges use `SegmentedPillControl`; coaching/patterns
use `InsightCard` tinted by `DomainTheme`; the mood row and coach CTA use `NoopCard` + `.noopGhost`;
synthesis carries a `ScoreStatePill`; copy is plain, USD, non-diagnostic, no LLM named; spacing is
`sectionGap` between sections and `gap` within; the macOS twin renders the same five sections in the detail
pane, the Android twin the same five as Compose `NoopCard`s.

---

## 4. Non-clinical / legal posture + the consolidated disclaimer surface

### 4.1 The cross-cutting posture (applies to every pillar)

NOOP is a **wellness and self-tracking tool, not a medical device**. This is already the law of the repo
(`DISCLAIMER.md §5`). v5 makes it a **design rule** every pillar inherits:

1. **No diagnostic verbs, anywhere.** Never *diagnose / treat / screen / detect a condition*. Skin-temp
   "illness watch" says *"your skin temp is further from your baseline than usual"* — an observation about
   *your own number*, never *"you may be ill."* Mind surfaces *patterns in numbers you entered*, never a
   mental-health finding.
2. **Approximations, labelled.** Charge/Effort/Rest, fitness age, skin-temp deviation, sleep stages, SpO₂,
   respiration are *approximations computed from published methods* (Task Force 1996 HRV, Karvonen %HRR,
   Edwards/Banister TRIMP, Nes/HUNT VO₂max). We **brand the method, never black-box it** — transparency is
   both the honesty differentiator and the legal cover.
3. **Crisis carve-out for Mind.** Anything mood/mental-health-adjacent carries the standing line *"If you
   are struggling or in crisis, contact a qualified professional or your local emergency service — do not
   rely on NOOP."* (DISCLAIMER §5.1, verbatim.)
4. **Your data, your device, your choice.** Imports/exports/Apple-Health surfaces restate that NOOP only
   moves data the user explicitly chooses, on-device, and can't see it afterward (DISCLAIMER §5.3).

### 4.2 One consolidated disclaimer surface (new in v5)

Today the disclaimer is spread across `DISCLAIMER.md`, per-screen footnotes, the Smart-alarm card, the
Mind card, the import screens, and `ScoringGuideView`. v5 adds **one canonical in-app surface** so the
posture is consistent and maintainable:

- **`AboutLegalView` (Swift) / `AboutLegalScreen.kt` (Kotlin)** — a single screen under **Settings → About
  & Legal**, rendering the `DISCLAIMER.md` sections (Independent/unofficial · Not a medical device · the
  per-feature carve-outs · Licensing · Takedown contact). It is the **one source of truth**; every
  per-feature disclaimer becomes a **short line + a "Learn more" link that deep-links into the matching
  section** of this surface, instead of restating paragraphs inline.
- **A reusable `DisclaimerNote` component** (Swift + Kotlin) — a small `footnote`-styled, `textTertiary`
  row with an optional "Learn more →" that deep-links to `AboutLegalView` at an anchor. Every pillar drops
  this at the foot of its hub section (skin-temp, Mind, imports, smart-alarm, scores). One component →
  every pillar's framing is automatically consistent and updates in one place.
- **First-run acknowledgment is unchanged** (the existing version-aware TERMS clickwrap gate); v5 just
  points its "read the full terms" link at `AboutLegalView`.

This is *consolidation, not new legal text* — the words already exist in `DISCLAIMER.md`/`TERMS.md`; v5
gives them a single home and a reusable surface so seven pillars can't drift.

---

## 5. v5 positioning + marketing one-liner

### 5.1 Positioning

**The category is "cloud-scored wearable apps." NOOP is the local-first, signal-first alternative.**
Every competitor (WHOOP, Oura, Garmin, Apple, Ultrahuman) ships you a number their server computed, behind
a subscription, and can't act on your body. NOOP's five-hub IA *is* the pitch:

- **Reasons from raw signals** (red/IR PPG, beat-to-beat R-R, 3-axis accel, skin temp) — not a cloud verdict.
- **Computes on-device** — no account, no cloud, no subscription, fully offline.
- **Can act on the body** via the strap haptic motor — the breathe/biofeedback pillar; *the only one that
  can breathe you back down.*
- **Fuses multiple devices locally** — WHOOP + generic BLE HR + imports, on your device.
- **Honest about limits** — Calibrating/Building states, "approximations not WHOOP's scores", never a
  diagnosis.

### 5.2 The one-liner (and supporting copy)

> **Everyone else shows you a score their cloud computed. NOOP computes from your raw signals, on your
> device, for free — and it's the only one that can breathe you back down.**

Tighter variants for different surfaces (all USD, no AI named, non-clinical):

- **App Store / Reddit subhead:** *"Your strap, your data, your device. NOOP reads the raw signals and does
  the math locally — recovery, strain, sleep, fitness age — no account, no cloud, no subscription."*
- **Six-word badge:** *"Raw signals in. On-device. Offline."*
- **The act-on-body hook (Breathe):** *"It doesn't just measure your nervous system — it can nudge it,
  with a guided breath the strap buzzes you through."*

Honesty guardrails on all marketing: WHOOP 4.0 is the supported path; 5/MG deeper metrics are *still being
figured out*; scores *build over a few nights*; nothing is medical; never claim to diagnose; never imply
WHOOP affiliation; never name the Coach's model.

---

## 6. Versioning, lockstep & phased ship plan

### 6.1 Versioning

- **One umbrella version: `5.0.0`**, shipped **lockstep** across macOS (CFBundle), iOS (project version)
  and Android (versionCode) — the established cadence. The IA reshuffle (this spec) is the **breaking
  visual change** that justifies the major bump; pillars then land as `5.1`, `5.2`, … fast-follows on the
  v5 IA.
- **Internal data keys never change.** The reshuffle is navigation + composition only; `recovery` /
  `strain` / `sleep_performance` / the metricSeries tall table / the workout table stay byte-identical so
  years of history + imports keep working (same principle as the Charge/Effort/Rest rebrand).
- **Value-for-value parity:** every UI/engine change reaches all three clients. Shared Swift packages +
  non-excluded `Strand/` files cover mac + iOS; Android always needs the Kotlin hand-port; build-verify all
  three centrally before the lockstep tag.

### 6.2 Phasing — what's MVP-in-v5 vs fast-follow

**v5.0.0 (MVP — the IA + guardrails, no new pillar engine):**
1. Re-point all three shells to the **five hubs** (`RootView` sidebar groups, `RootTabView` 5-slot bar +
   retire More, `AppRoot` 5 drawer groups + 4-tab bar). Every existing screen reachable in ≤ 2 taps.
2. Compose the hubs from existing screens-as-sections (Health already is; make Insights + Devices&Sources
   the same way). No feature behaviour changes.
3. Ship the **consolidated disclaimer surface** (`AboutLegalView`/`AboutLegalScreen` + `DisclaimerNote`
   component) and re-point every inline disclaimer at it.
4. Enforce the **design-language guardrails** (audit for raw hex / ad-hoc cards / magic spacing introduced
   by recent features; fix to tokens/components).
5. Land the **positioning copy** (README, store/AltStore source, Reddit launch post draft).

**v5.x fast-follows (each pillar onto the v5 IA, lockstep, one per release):**
- `5.1` Skin-temp section in Health (sibling spec).
- `5.2` Mind mood check-in + correlations section in Insights (`2026-06-12-noop-mind-*`).
- `5.3` Breathe/HRV haptic biofeedback as a first-class FAB action + Insights outcome cards (sibling spec).
- `5.4` Third-party imports consolidated under Devices & Sources (`2026-06-12-noop-third-party-imports-*`).
- `5.5` Fitness-age / multi-source band surfaces finalised in Health + Devices (`2026-06-15-multi-source-*`).
- `5.6` Coach single entry in Insights, opt-in BYO-key (sibling spec).
- GPS workouts (`2026-06-10-gps-workout-activities-*`) lands whenever its Android engine is ready; it needs
  no new nav (Today FAB → Workouts).

Each fast-follow must satisfy **Rule of 5 / 5 / 2** and drop a `DisclaimerNote` — that's the merge gate.

---

## 7. Architecture & files (what to build, what to reuse)

This umbrella is **mostly composition**, not new engine code — but it adds two shared primitives.

**Reuse (no change):** `StrandPalette`/`Palette`, `StrandFont`, `StrandMotion`, `NoopMetrics`,
`DomainTheme`, and the whole locked component set (`NoopCard`, `StatTile`, `ChartCard`, `InsightCard`,
`SectionHeader`, `SegmentedPillControl`, `SourceBadge`, `ScoreStatePill`, the three button styles, all
gauges/charts). All seven pillars compose from these.

**New, shared (small):**
- `DisclaimerNote` — a `StrandDesign` component (Swift) + Kotlin twin in `android/.../ui` (Compose). Pure
  view, token-only, optional deep-link anchor. **Unit-tested** for: renders the standing copy, deep-link
  anchor resolves, USD/no-LLM/no-diagnosis copy lint (a string-content test guards the wording).
- `AboutLegalView.swift` (`Strand/Screens`) + `AboutLegalScreen.kt` (`android/.../ui`) — render the
  `DISCLAIMER.md` sections from a single in-app `LegalContent` model so mac/iOS/Android read identical text.
  A tiny `LegalContent` value (could live in `StrandDesign` or a small shared file) holds the section
  text + anchors; **one parity test** asserts Swift and Kotlin `LegalContent` carry the same section ids.

**Changed (navigation only):** `RootView.swift` (sidebar → five `Section`s), `RootTabView.swift` (5-slot
bar, retire `moreTab`), `AppRoot.kt` (`drawerGroups` → five, `bottomTabs` → four + FAB), `NavRouter`
(address hub + section anchor). No screen's *content* changes in 5.0.0.

**No engine package work in 5.0.0** — `StrandAnalytics` and its Kotlin twin are untouched by the IA
reshuffle; pillar engines land in their own fast-follows per their specs.

---

## 8. Cross-platform plan

- **Shared first.** The five-hub IA, the `DisclaimerNote` copy, and the `LegalContent` text are defined
  once; mac + iOS consume the Swift component, Android hand-ports the Compose twin with identical strings.
- **Per-platform shells differ by idiom, not by destinations.** macOS = grouped sidebar; iOS = 5-slot tab
  bar + FAB; Android = 5-group drawer + 4-tab bar + FAB. All three resolve the **same five hubs** and the
  **same in-hub sections**, so a feature is in the same logical place on every device.
- **Deep-linking parity.** Android already has `vital_detail/{key}`; mac/iOS gain the equivalent
  hub-section anchors via `NavRouter`. The consolidated disclaimer deep-links work on all three.
- **Build-verify centrally.** Per the lane/gradle rule: agents don't each run gradle; build-verify
  mac (universal `generic/platform=macOS` + lipo-gate) + iOS (app-build CI) + Android (clean
  `assembleFullRelease`) once, centrally, before the lockstep tag.

---

## 9. Test plan

- **Nav reachability test (all 3):** every former destination is reachable in ≤ 2 taps from a cold start;
  a table-driven test asserts each `NavItem`/`Destination`/`More`-row maps to exactly one hub + section.
- **No-orphan test:** the set of pre-v5 destinations == the set reachable post-v5 (nothing dropped).
- **`DisclaimerNote` content lint (Swift + Kotlin):** copy contains the standing non-clinical line, contains
  no diagnostic verb (`diagnose/treat/screen`), names no LLM/AI, uses `$`/USD not `GBP`. A failing string
  blocks merge — this is the automated guard on the legal posture.
- **`LegalContent` parity test:** Swift and Kotlin section ids + anchors are identical (the disclaimer can't
  drift between platforms).
- **Design-token lint (CI):** grep gate — no raw `Color(hex:` / `0x` colour literals in `Strand/Screens`
  or `android/.../ui` outside the palette files; no `.font(.system(size:` outside `StrandDesign`. (Extends
  the existing palette-bypass count discipline.)
- **Snapshot the Insights example screen** (the §3.4 reference) on iPhone light + dark so the resolved
  target is regression-guarded; mac + Android equivalents.
- **Cross-platform parity** stays green for every shared change (Swift ↔ Kotlin same outputs), per the
  established suite.

---

## 10. Open questions

1. **iOS 5-slot bar vs 4 + FAB:** is a five-icon bottom bar + a sixth gold FAB too dense on a small iPhone?
   Option B: keep four content tabs (`Today · Insights · Health · Sources`) and put **Settings only** in
   the per-hub gear (already proposed) — that's actually 4 + FAB. Confirm the gear-only Settings entry
   reads as discoverable, or give Sources/Settings a shared slot.
2. **macOS sidebar: groups vs a true two-level disclosure?** Five `Section`s with ~4 rows each is ~20 visible
   rows — better than 23 flat, but is collapsible disclosure (only the active hub expanded) cleaner, or does
   that hide things the desktop user wants always-visible?
3. **Where does Smart Alarm live** — a Today card (action) or a Settings/Automations section (setup)? Likely
   both: a Today *status* card + a Settings *setup* screen. Confirm.
4. **"Insights" naming collision.** There's already an `Insights` screen *and* an `Intelligence` screen.
   v5 makes Insights a *hub* that contains the old Insights-screen content as one section — do we rename the
   old screen ("Patterns"? "Journal"?) to avoid "Insights inside Insights"? (The §3.4 mock uses "Patterns"
   for the correlations and keeps Mind/Coach distinct — adopt that.)
5. **Does the consolidated disclaimer satisfy the per-feature legal need**, or do high-risk pillars (Mind,
   skin-temp illness-watch) still need an *inline* full disclaimer the user can't miss, not just a "Learn
   more" link? Lean: inline short line + link is fine for most; Mind's crisis line stays inline in full.
6. **Versioning:** does the IA reshuffle alone warrant `5.0.0`, or hold the major for the first shipped
   pillar and call the reshuffle `4.10.0`? (Spec assumes 5.0.0 = the IA; pillars are 5.x.)
7. **Marketing claim review:** "the only one that can breathe you back down" — confirm no competitor ships
   a strap-haptic guided-breath today; if one does, soften to "one of the only." (Honesty rule.)
