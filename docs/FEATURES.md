
# NOOP — Feature Guide

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and 5.0). It pairs
directly with the strap over Bluetooth Low Energy — **no WHOOP account, no
cloud** — stores everything on-device in SQLite, imports your WHOOP and Apple Health exports,
and computes its own daily scores locally — **Charge** (recovery), **Effort** (strain) and **Rest**
(sleep), an energy economy you wake with, spend, and rebuild — alongside HRV and the raw signals.
These are honest approximations from published methods, **not WHOOP's scores**. The macOS app (in `Strand/`) is the
reference implementation (installable via the Homebrew cask); Android (in `android/`) is a full,
shipped app (sideload the `.apk`); and iOS ships as an **unsigned `.ipa` you sideload** with
AltStore/SideStore — signed on your own iPhone with your own free Apple ID, so there's no App
Store or developer account and NOOP stays anonymous (see [docs/IOS.md](IOS.md); you can still
build it yourself in Xcode). It shares NOOP's analysis code, so its results match
macOS; it is newer and less battle-tested, with live BLE on a physical iPhone not yet fully
validated.

> **Not affiliated with WHOOP.** NOOP is independent interoperability software for *your own*
> device and *your own* data. "WHOOP" is used only to identify the hardware NOOP talks to.
> **NOOP is not a medical device** — every metric (HR, HRV, Charge, Effort, Rest, SpO₂,
> respiration, skin temperature) is an approximation, not a clinical reading, and must not be
> used to diagnose, treat or make health decisions.

NOOP is built on community interoperability and protocol-documentation work, with thanks to:

| Project | Contribution |
| --- | --- |
| [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop) | WHOOP 4.0 BLE protocol — framing, commands, decoding |
| [`b-nnett/goose`](https://github.com/b-nnett/goose) | WHOOP 5.0 / MG BLE protocol |
| [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) | On-device SQLite persistence |

---

## At a glance

NOOP is a `NavigationSplitView`: a left sidebar of screens, a live connection status pill
pinned to the sidebar's bottom (bonded / connecting / disconnected, with battery %), and a
detail pane. A menu-bar item gives a glanceable live heart rate from anywhere. The whole UI is
dark, and a first-run wizard walks you through pairing.

Screens are grouped below by whether they need a connected strap:

| Needs a connected strap (live BLE) | Works from imported data alone |
| --- | --- |
| Live, Breathe (for haptics), Intervals (for haptics), Health Monitor (live HR), Automations (to act), Notifications (to buzz) | Control Center, Explore, Compare, Insights, Sleep, Trends, Workouts, Stress, Mind, Apple Health, Data Sources |

Most of NOOP works the moment you import an export. The strap adds the *live* layer — real-time
heart rate, haptic cues, and physical-input automations.

---

## Connection states

Throughout the app the strap reports one of three states:

- **Disconnected** — no strap found (critical / red dot).
- **Connecting** — found and connecting, finishing the secure pairing handshake (warning / amber).
- **Bonded** — paired and streaming; haptics and live HR are available (positive / green).

> WHOOP straps do **not** appear in *System Settings → Bluetooth*. They advertise on a custom
> profile that only apps like NOOP can find — so there's nothing to pair in System Settings.

Commands that drive the strap motor (any wrist buzz) and the live realtime stream require a
**bonded** connection. Where a feature needs this, it is noted below and the button is disabled
until you bond.

---

## First-run onboarding

The onboarding wizard (`OnboardingWizard.swift`) appears on first launch and runs once
(tracked by the `noop.onboarded` preference). It is a calm, paged flow with a progress
"thread" along the bottom and a Back button always available:

1. **Welcome** — "all your data, none of the cloud".
2. **What NOOP does** — three value slides: the Charge ring, live heart, offline ownership.
3. **Bluetooth priming** — explains *before* the macOS Bluetooth prompt that nothing leaves
   your Mac; the connection is local BLE with no server in the middle.
4. **Wear & wake** — put the strap on (snug, sensor on skin), charge it, keep it within ~1 m.
5. **Scan** — a radar sweep; tapping **Scan** calls the BLE engine. If it hasn't bonded after
   ~12 seconds, a reassurance card appears explaining the strap won't show in System Settings,
   that only one host can hold it at a time (close the WHOOP phone app), etc.
6. **Bonded celebration** — a Charge ring blooms in when the strap bonds, with battery %.
7. **Profile** — age, sex, weight, height (feeds zones, calories and baselines). Shows your
   estimated max heart rate.
8. **Import (optional)** — points you to Data Sources; fully skippable.
9. **Done** — "Your thread starts here."

You can revisit pairing and profile any time from **Settings**.

---

## Control Center

**Sidebar: Today · works from imported data; live status shown in the sidebar.**

The home dashboard (`TodayView.swift`, titled "Control Center"). A tight, gapless grid:

- **Health alert banner** — the illness early-warning banner appears here when triggered (see
  [Illness early-warning](#illness-early-warning)).
- **Today's Synthesis** — the signature **Charge Ring** (HRV and resting HR underneath) beside
  a plain-English read-out ("Charge is strong and sleep was consistent.") and a state
  word (Depleted / Low / Steady / Primed / Peak). NOOP frames the day as an energy economy: you
  **wake with Charge**, **spend it as Effort**, and **rebuild it with Rest**.
- **Key Metrics** — a uniform tile grid, each with a 14-day sparkline: Charge, Effort
  (of 100), Rest (hours + efficiency), HRV, Resting HR, Blood Oxygen, Respiratory,
  Steps (on-device only for WHOOP 5/MG; on a 4.0, NOOP shows your imported Apple Health /
  Health Connect steps, because it can't yet read steps off the 4.0 strap over Bluetooth —
  the 4.0 itself does count steps in the official WHOOP app — and approximate),
  Weight, Calories. WHOOP metrics come from the `my-whoop` source; Steps/Weight/Calories/
  Respiratory pull from `apple-health`. Sparse series (e.g. weight) fall back to all history so
  a tile never shows empty when data exists.
- **Last Workouts** — up to six recent sessions as tiles (duration, date, avg HR, kcal).
- **Data Sources** — a footer showing whether WHOOP and Apple Health data are present, with day/
  session counts.

---

## Live

**Sidebar: Live · needs a bonded strap for HR; the hardware-test surface.**

`LiveView.swift` is the real-time heart-rate screen and the pairing/diagnostics surface:

- A large **smoothed heart rate** (BPM) — NOOP shows a spike-filtered median over a ~10 s
  window, not the raw per-beat value, so it's stable. Recent **R-R intervals** (ms) are listed
  beneath.
- **Status grid** — battery %, last decoded frame type, last decoded event.
- **Controls**:
  - **Scan & Connect / Re-scan** — start or restart BLE scanning.
  - **Buzz strap** — fire a test haptic buzz (requires a **bonded** connection).
  - **Disconnect** — drop the connection.
- A scrolling **BLE log** of frames, events and actions — useful for confirming the strap is
  streaming.

Opening Live starts the realtime HR stream and requests a fresh battery reading; leaving it
stops the realtime stream (the lightweight standard HR keeps recording).

---

## Breathe

**Sidebar: Breathe · works visually without a strap; needs a bonded strap for haptic cues.**

`BreathingView.swift` / `BreatheScreen.kt` / `WatchBreatheView.swift` — an **HRV haptic breathing
biofeedback** trainer (NOOP's flagship novel feature), now also a **content-driven protocol
catalog**. Because the strap both *measures* HRV (from R-R intervals) and *buzzes*, NOOP can pace
your breath with a felt cue and watch your HRV respond in real time.

- **Pick a pace** from the in-place pill row:
  - Built-in: Relax 4-6, Coherence 5.5, plus a **catalog** of ANS protocols (Deep, Box 4-4-4-4 with
    holds, Diaphragmatic, Alternate Nostril, 4-7-8, Buteyko, Tummo, Ujjayi, Bhastrika, Qi Gong,
    Soma, Coherent 6-6, …) and **Presence Process** tempos (Regular / Mid / Punching Through —
    consciously connected breathing, no holds).
  - **Guided** entries (Kapalabhati, Holotropic, Wim Hof, Shamanic) give education + a session timer
    without an aggressive auto-pacer.
  - Locked **Resonance** pill still appears after a Resonance sweep.
- **Session length**: Open (until Stop) or **5 / 10 / 15 min** with auto-stop; defaults follow each
  protocol's recommended duration (e.g. Presence → 15 min).
- **ⓘ Protocol info** — background, session hint, and cautions (localized; non-clinical). Presence
  paces include a short Presence Process / CCB intro.
- **Start a session** — liquid vessel fills on inhale, holds steady on hold, drains on exhale; live
  BPM in the centre. Bonded strap: **one pulse on inhale, two on exhale** (holds are silent).
  Without a strap it's visual-only ("Visual only" pill).
- **Live readouts**: heart rate, rolling **HRV (RMSSD)**, and stage timing.
- **Coherence estimate** and **pre/post RMSSD outcome** unchanged (estimates, not clinical).
- Modes **Resonance** and **Calm me** stay on the existing mode strip.

Pure schedule math lives in `Packages/StrandAnalytics` (`BreathProtocol` / `BreathProtocolCatalog` /
`BreathProtocolPlayer`) with a Kotlin twin under `com.noop.analytics` — golden-vector tested.

Technique list and timing hints are inspired by publicly documented ANS breath protocols (including
[Ultrahuman's ANS breath protocols blog](https://www.ultrahuman.com/blog/harness-the-power-of-breath-protocols-for-your-autonomic-nervous-system/));
NOOP is not affiliated with Ultrahuman. Education copy is original. Presence tempos were measured
from public Presence Process guide audio.

A "Test buzz" button fires a single pulse (bonded only).

---

## Intervals

**Sidebar: Intervals · works visually without a strap; needs a bonded strap for haptic cues.**

`IntervalTimerView.swift` — a **silent haptic HIIT interval timer**. Train hands-free: the strap
buzzes every transition so you never look at the screen.

- **Configure** Work seconds (5–600), Rest seconds (5–600) and Rounds (1–30).
- A big glanceable **stage face**: WORK / REST / DONE, the current round, a countdown ring, and a
  total-session progress bar (elapsed / planned).
- **Haptic cues** (bonded strap): a strong triple-buzz into each WORK block, a short single buzz
  into REST, a 3-2-1 tick on the last seconds of each phase, and a long 5-loop buzz when the
  session finishes.
- **Start / Pause / Restart** and **Reset**.

With no strap bonded it still works as a large visual timer (without haptics), prompting you to
bond on the Live screen.

---

## Explore (Metric Explorer)

**Sidebar: Explore · works from imported data.**

`MetricExplorerView.swift` — a catalog of every signal, one tap deep. The root is a grouped list
(by `MetricCatalog` category); a faint trailing dot marks metrics with no recorded data. Tapping a
metric opens its **detail dossier**:

- A **W / M / 3M / 6M / 1Y / ALL** range control.
- A hero **trend chart** with the latest value and "as of *date*".
- A uniform stat row: **Average, Min, Max, Latest, and Δ vs the previous equal-length window**
  (tinted by whether the change is the "good" direction for that metric).
- **What correlates** — a cross-catalog Pearson scan over the visible window (|r| ≥ 0.30,
  n ≥ 10), top 6, each with an r-bar.

Sparse metrics (weight, body fat) auto-widen the window when the selected range holds no points,
and flag that they did, so you always see real data instead of an empty state.

---

## Compare

**Sidebar: Compare · works from imported data.**

`CompareView.swift` — overlay **2–4 metrics** from the catalog and read how they move together:

- Pick metrics from a grouped menu; selected metrics show as removable colored chips.
- A **W / M / 3M / 6M / 1Y / ALL** range control.
- A **normalized overlay chart** — each line min–max scaled to 0–1 within the window so different
  units share an axis. Hovering shows a crosshair and a tooltip with every series' **real** value
  on the nearest day; the legend lists each series' true min–max range.
- **How They Move Together** — every selected pair gets a live **Pearson r** with a plain-English
  conclusion ("When weight rises, Charge tends to fall — a moderate negative link.").

Sparse series auto-widen so they still overlay against dense ones.

---

## Insights

**Sidebar: Insights · works from imported data (needs WHOOP journal answers for behaviour effects).**

`InsightsView.swift` — "interrogate what affects what", in two halves:

1. **Behaviour Effects** — splits your logged WHOOP **journal** answers (Alcohol, Caffeine, Late
   meal, Meditation…) into days each behaviour *was* vs *was not* logged, then compares a chosen
   outcome (Charge / HRV / Rest / RHR) between the two groups. Each effect card shows a
   plain-English sentence, the with/without means and group counts, a **SIGNIFICANT / EXPLORATORY**
   pill, and an effect size (**Cohen's d**) with a magnitude word. Tint is sign-aware: a behaviour
   that moves the outcome the "good" way reads positive/green, the "bad" way reads red. Without
   journal data, NOOP explains how to start logging.
2. **Metric Relationships** — a curated set of **Pearson** correlations: Rest ↔
   Charge, HRV ↔ Charge, Resting HR ↔ Charge, and Charge → next-day Charge (1-day lag).
   Each is a one-line insight with r, a significance pill, an r-bar, and a strength/direction reading.

---

## Sleep

**Sidebar: Sleep · works from imported WHOOP data.**

`SleepView.swift` — last night, read in two seconds — and **browse back through past nights**, not
just the most recent (step through earlier nights to compare):

- **Stage breakdown hero** — a **hypnogram** (reconstructed from stage durations) or, if intervals
  can't be reconstructed, a proportional stacked stage bar. Footer shows REM / Deep / Light / Awake
  each as "Xh Ym · NN%", with time-in-bed, efficiency, and onset–wake times.
- **Night detail** — a uniform tile grid, each with a sparkline and a "vs typical" caption: Sleep
  Performance, Efficiency, Consistency, Hours vs Needed, Restorative (deep + REM share),
  Respiratory, and Sleep Debt (vs your personal sleep need, floored at 7.5 h).
- **Stages vs typical** — Deep / REM / Light as horizontal bars, last-night minutes with a marker
  at your personal mean, so highs and lows pop.
- **Asleep duration** — a trailing-30-night hours trend with avg / min / max.

If no sleep sessions are imported, NOOP points you to Data Sources.

---

## Trends

**Sidebar: Trends · works from imported WHOOP data.**

`TrendsView.swift` — the longitudinal view ("the thread of you over time"):

- A **W / M / 3M / 6M / 1Y / ALL** range control (default 3M).
- A hero **Charge** chart with avg / peak / low / day-count.
- **Daily signals** — small multiples for **HRV**, **Resting HR** and **Effort**, each with
  mean / min / max.
- A **Charge year heat-strip** — a calendar of Charge scores across the past year (or all
  history on ALL), with a depleted→peaked legend.

Windows are taken relative to your latest recorded day and auto-widen on sparse data.

---

## Workouts

**Sidebar: Workouts · works from imported WHOOP and Apple Health data.**

`WorkoutsView.swift` — the activity log, threaded together:

- A **7D / 30D / 90D / 1Y / All** range control (auto-picks the tightest range with ≥2 sessions).
- **Summary tiles** — Total Workouts, Total Time, Total Calories, Total Distance, Most Active sport.
- **Activity Breakdown** — per-sport cards (sessions, time, kcal, avg per session), sport-specific
  icons.
- **All Sessions** — a uniform table: date/time, sport, duration, avg HR, kcal, distance, and a
  **source badge** (WHOOP or Apple) per row.

---

## Health Monitor

**Sidebar: Health · live HR needs a bonded strap; vitals come from imported WHOOP data.**

`HealthView.swift` — live vitals:

- **Live heart rate hero** — a streaming HR sparkline tinted by zone, with a zone pill, "% Max",
  your Max HR (from Settings) and a streaming/idle state. When the strap reports HR as 0, NOOP
  derives it from the latest R-R interval and notes "from R-R".
- **Vital Signs** — a tile grid from your most recent imported day: Respiratory Rate, Blood O₂,
  Resting HR, HRV and Skin Temp, each colored by whether it sits in a healthy range ("In range" /
  "Out of range").

With no live HR and no imported day, NOOP prompts you to connect or import.

---

## Stress

**Sidebar: Stress · works from imported WHOOP data.**

`StressView.swift` — a clear, single-number **Stress Monitor** (0–3) with a LOW / MEDIUM / HIGH
band and one plain-English line on *why*:

- Today's value is your **recorded daily stress score** if one exists; otherwise NOOP **derives**
  it transparently — comparing today's resting HR and HRV to your own 30-day baseline (higher RHR
  and lower HRV both push stress up), combining two z-scores and squashing onto 0–3 with a logistic
  curve (0 calm · 1.5 baseline · 3 high).
- A semicircular **gauge** (its own blue → mint → amber ramp, deliberately not the Charge traffic
  light), the band, and an explanation tuned to your RHR/HRV shifts.
- **Today's markers** — the stress value (with sparkline), Resting HR and HRV vs baseline (tinted
  toward stress or Charge), and "Calm time" (share of recent days in the LOW band).
- A multi-range **trend** chart.
- A **"How this is computed"** card laying out the exact method and band legend.

---

## Mind

**Sidebar: Mind · works from imported data; logs your own daily check-in.**

A quick **daily mood check-in** and a place to see how it tracks against your body's signals over
time:

- **Daily mood check-in** — log how you feel each day in a few taps. Stored on-device alongside
  the rest of your history.
- **Correlations** — once you've logged enough days, NOOP lines your mood up against your own
  **Charge, Rest, HRV** and other metrics, so you can see what actually moves it (e.g. "lower
  HRV days tend to read lower mood").
- **Non-clinical by design** — this is a personal self-reflection log, **not** a mental-health
  assessment, diagnosis or therapy. It never leaves your device.

---

## Apple Health

**Sidebar: Apple Health · works from imported Apple Health data.**

`AppleHealthView.swift` — the per-source page for everything imported from the `apple-health`
source, read locally on this Mac:

- A **W / M / 3M / 6M / 1Y / ALL** range control.
- **Tiles**: Steps, Resting HR, HRV, VO₂ Max, Weight, Body Fat, Lean Mass, Asleep avg, Workouts.
- **Chart sections** — Heart & Vitals (resting HR, HRV, blood oxygen, respiratory rate), Activity
  & Energy (steps, active energy), Body Composition (weight, body fat, lean mass, BMI), and Sleep
  (asleep). Each chart has an avg / min / max / point-count footer.

Sparse weekly series (weight, body fat) auto-widen to all history so a short window is never empty;
a single reading is shown as a "Latest reading" value rather than an empty chart.

---

## Data Sources

**Sidebar: Data Sources · the import hub. Everything stays on this Mac.**

`DataSourcesView.swift` — bring your history in once, then it's yours:

### WHOOP Export (CSV)
Import your full WHOOP history — recovery, strain, sleep, workouts — from a WHOOP data export
(`.zip` or unzipped folder). Works for WHOOP 4.0, 5.0 and MG. Get one from
*app.whoop.com → Data Management*. NOOP reports the records imported and the date span, and shows
how many days and sleeps are stored.

### Apple Health
Import an Apple Health export (`export.zip`) from *Health app → profile → Export All Health Data*.
NOOP **streams and aggregates** it locally — years of HR, HRV, sleep, SpO₂, steps, body
composition and more. Large exports take a minute or two.

### Nutrition (CSV)
Import a daily-nutrition CSV exported from **Cronometer** or **MacroFactor** to bring calories and
macros onto the same timeline as your Charge, Rest and HRV — so you can explore and correlate
food against how you feel. Parsed locally; nothing is uploaded.

### WHOOP Strap (Live BLE)
Shows whether the strap is bonded and streaming. Pairs directly over Bluetooth — no WHOOP app,
no cloud. Open **Live** to pair if it isn't connected.

All imports run on-device; nothing is uploaded. WHOOP data is stored under the `my-whoop` source
and Apple Health under `apple-health`, so per-source pages and cross-source consensus stay distinct.

---

## Notifications

**Sidebar: Notifications · needs a bonded strap to buzz; settings save without one.**

`NotificationSettingsView.swift` — choose which Mac apps tap your wrist, and how. Everything runs
on this Mac.

- **Wrist alerts** master switch (opt-in, **off** by default). A test buzz fires immediately
  (bonded only). Strap status mirrors the connection state.
- **Per-app control** — NOOP discovers installed, notification-capable apps via macOS
  (LaunchServices) and groups them: **Email** (Outlook, Mail), **Messaging** (WhatsApp, Messenger,
  Messages, Discord, Slack, Telegram, Signal), **Meetings & Calls** (Teams, Zoom, FaceTime), and
  **Calendar & Reminders**. Each app shows its real icon, an on/off switch, and a **buzz pattern**
  picker — **Single / Double / Triple / Long** — with a per-app test button.
- **Behaviour** — "Only buzz when worn", and **Quiet hours** (mute wrist alerts overnight, with
  a from/to time picker; default 22:00–07:00).

> Wrist *delivery* of macOS notifications is not live yet — it needs a small on-device watcher
> (coming in an update). Your per-app choices and patterns are saved now and apply automatically
> once delivery ships. Everything stays on this Mac.

---

## Automations

**Sidebar: Automations · needs a bonded strap to act/buzz; settings save without one.**

`AutomationsView.swift` — turn the strap's physical inputs and live biometrics into Mac actions
and haptic coaching, all on-device.

### Double-tap → Mac action
Double-tap the strap to trigger an action on this Mac. Pick one of:

| Action | What it does |
| --- | --- |
| Nothing | No action |
| Lock the Mac | Locks the screen immediately (falls back to a "Lock Screen" Shortcut) |
| Buzz back (confirm) | Fires a confirming wrist buzz |
| Mark a moment | Records a timestamped "moment" (with a confirming buzz) |
| Run a Shortcut… | Runs any macOS Shortcut by name |

A **Test action** button runs it without the strap. Recent moments are listed and can be cleared.

### Wear & presence
React when the strap comes off or goes on:

- **Lock the Mac when I take the strap off** — fires the moment the strap leaves your wrist.
- **Run a Shortcut when taken off** — presence automation (set a Focus, pause media, set away…).
- **Run a Shortcut when put back on** — reverse it when you return.

> macOS reserves true auto-*unlock* for Apple Watch, so this can **lock**, not unlock.

### Haptic coaching
- **HR-zone coaching** — buzz when you hit your top zone (ease off) and again when you recover,
  using your max HR from Settings.
- **Stress check-ins (haptic)** — offer a guided breathing check-in after a fresh HRV dip while
  you are still. Off by default, with optional auto-nudges, quiet hours, and your resonance pace.

### Smart alarm
Wake to a wrist buzz. This arms the strap's **own firmware alarm**, so it still fires even if the
Mac is asleep or NOOP is closed. Set your wake time — the strap buzzes at exactly that time.
NOOP does not currently do light-sleep early wake.

Mac side-effects are sandbox-friendly: screen lock uses macOS's own lock entry point, and
Shortcuts run via the `shortcuts://` URL scheme — anything you can build in Shortcuts is reachable.

---

## Illness early-warning

NOOP watches for the classic early-illness/strain signature on-device. It compares your last ~2
days against a ~28-day baseline (ending 3 days ago) for resting HR, HRV, skin-temperature
deviation and respiration. When **two or more** anomalies appear — e.g. resting HR up ≥5 bpm,
HRV down ≥20%, skin temp up ≥0.6 °C, respiration up — a banner appears on **Control Center**:
*"Your body looks strained — … Consider taking it easy."*

On a banner transition from clear to raised, NOOP also posts a **system notification** (at most
once per local day) so the warning reaches you when the window is closed. The toggle lives in
**Automations → Illness early-warning**. The defaults differ by platform on purpose: macOS is
**opt-in** (off by default — enabling it triggers the notification-permission prompt), while
Android is **opt-out** (on by default — the watch has always run there). Needs at least 14 days
of history. On-device and approximate — informational only, **not** a diagnosis.

---

## Settings

**Sidebar: Settings · always available.**

`SettingsView.swift`:

- **Profile** — age, sex, weight, height, and max heart rate (auto-estimated via Tanaka, or a
  manual override). These power your zones, calorie estimates and Charge baselines.
- **Step calibration** — tune the stride/step estimate to your own walking so step and distance
  figures read closer to reality.
- **Units** — choose your preferred measurement units (metric / imperial) across the app.
- **Strap** — connection status, battery, and Re-scan / Disconnect controls.
- **Export for Shortcuts (iOS)** — a **HealthKit-free** path that hands your NOOP metrics to Apple
  Health via the Shortcuts app, so an anonymous build (with no HealthKit entitlement) can still get
  data into Health on your terms.
- **About** — version, the "all your data, none of the cloud" note, a **medical disclaimer**, and
  attribution to the community protocols NOOP is built on.

---

## Menu-bar item

NOOP lives in the macOS menu bar (`MenuBarContent.swift`). The label is a zone-tinted heart dot
plus the live HR (or "—" when not streaming). Clicking it opens a compact popover: a Charge
ring, the live heart rate, battery / resting HR / HRV, and quick actions to start/stop the live
feed, refresh battery, scan/reconnect, or disconnect.

---

## Support

**Sidebar: Support · always available. NOOP is free and always will be.**

`SupportView.swift`:

- **Built on** — credit to the community interoperability projects NOOP stands on.
- A reminder: **not affiliated with WHOOP; interoperability software for your own device and
  data; not a medical device.**

---

## Privacy & data ownership

- **Offline by design.** NOOP talks to your strap directly over Bluetooth Low Energy — there is
  no server in the middle. No account, no sync, no cloud.
- **On-device storage.** All history (imported and live-captured) is stored locally in SQLite
  via GRDB.
- **Your data is yours.** Imports happen once and stay on this Mac; nothing is uploaded.
