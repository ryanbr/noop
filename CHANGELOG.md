# Changelog

All notable changes to NOOP. NOOP is an independent, experimental project — not the WHOOP app, and
not affiliated with WHOOP. It reads a strap you own, on your own device, fully offline. Dates are
approximate; downloads are on the [Releases](https://noop.fans/NoopApp/noop/releases) page.

## What to expect

- **Independent, and experimental.** Treat NOOP as a capable work-in-progress rather than a finished
  product.
- **WHOOP 4.0 is the supported path.** It is tested and works end to end. WHOOP 5.0/MG is newer: live
  heart rate works today, but deeper metrics (recovery, strain, sleep) for 5/MG are still being
  figured out. NOOP always tells you what's live versus still building.
- **Your scores build over a few nights.** Live heart rate is instant; recovery, strain and sleep
  sharpen as NOOP learns your baseline. Import your WHOOP export to backfill your history instantly.
- **Everything stays on your device.** No account, no cloud, no sync.

---

## 5.0.0 — v5: the raw-signal release (all platforms)

**The biggest release in NOOP's history.** Everyone else shows you a score their cloud computed, behind a
subscription. NOOP reads your strap's *raw signals* — beat-to-beat R-R timing, red/IR PPG, 3-axis motion,
skin temperature — and does all the maths **on your own device, free and offline**. v5 turns NOOP into a
raw-signal platform: it reasons from those signals, computes everything locally, and is the only one of
these apps that can *act on your body* through the strap's haptic motor. Seven new pillars, plus a tidier
home — every screen now lives under **five places: Today · What Moves You (Insights) · Health · Devices &
Sources · Settings**, so nothing is buried. Nothing about your data or your history changed; it just has a
coherent home and a lot more to show you. Everything below is on-device, opt-in, and honest about its
limits.

- **Haptic biofeedback — "the strap that breathes you down."** The flagship. NOOP can now *act* on your
  nervous system, not just measure it. Your wrist motor paces your breathing with the screen off, and you
  get a measured outcome.
  - **Resonance breathing.** Find your personal calm pace (the breathing rate, roughly 4.5–7 breaths/min,
    that gives your heart its biggest healthy swing): **Breathe → Resonance → "Find your resonance pace"**,
    then pick the **Full sweep (~13 min)** or **Quick sweep (~7 min)**. NOOP paces you through candidate
    paces, reads which one your body responds to most, and locks it. After that, the Breathe session uses
    your locked pace, and you get the usual "+X% vs start · peak Y ms" outcome.
  - **"Calm me · 3 min."** On a stressed moment (the Stress screen / the check-in card), tap **Calm me ·
    3 min** for a felt metronome that buzzes a few beats below your live heart rate so your heart can drift
    down toward it. Honest about it: if your HR doesn't fall, it says so — no fake win.
  - **Passive stress check-ins (haptic).** Optional, **off by default**: **Settings → Automations → "Stress
    check-ins (haptic)"**. When your HRV dips while you're *still* (not exercising), NOOP offers a one-minute
    breathing cue with a single confirming buzz and a dismissible card — never an alarm, never a diagnosis.
    All three layers are PPG-derived estimates, relaxation guidance, not a medical treatment.
- **What Moves You — your personal n-of-1 insights.** Competitors show population averages ("alcohol
  typically lowers recovery"). NOOP computes the effect **on your own data**. A ranked, **lag-aware** feed
  ("what actually moves *your* Charge", with a "next morning / same day" chip and a confidence pill — Solid
  / Building / Calibrating) replaces the old behaviour list. Log **alcohol** or **late caffeine** with an
  *amount* and NOOP fits a personal **dose-response** curve (shrinking toward typical patterns until you've
  logged enough nights, then becoming truly yours). In the evening, the **damage forecast** on Today tells
  you what one more drink tends to cost tomorrow's Charge, with an honest range. Everything is framed as
  "patterns in your own data" — association, never cause. Open **What Moves You** (the wand entry in the
  sidebar / Insights).
- **Skin-temperature suite — three features off one underused signal.** WHOOP already streams skin
  temperature every night; NOOP already banks it. v5 reasons from it three ways, **all on-device, free**:
  - **Cycle awareness (opt-in).** A coarse menstrual-cycle phase (Follicular / Peri-ovulatory / Luteal) read
    from your nightly skin temperature, corroborated by your resting-HR and HRV pattern. Turn it on in
    **Health → Skin temperature → "Turn on cycle awareness"**. It is **awareness only — not contraception,
    not a fertility predictor, not a medical service** — and a period estimate is always a *window*, never a
    hard date. This is the kind of data a cloud product can't promise stays private; NOOP's can, because it
    physically never leaves your device.
  - **Body clock.** A jet-lag / shift-work helper that estimates your body-clock phase from your nightly
    temperature low and your rest-activity rhythm ("about 25 min later than your schedule") and gives a
    light + sleep-timing plan for a trip or new shift. Light and sleep timing only — never supplements.
  - **Heads-up (illness early-warning).** The old illness banner cried wolf after a night out. The new one
    scores resting-HR, HRV, skin-temp and respiration anomalies *and cross-checks your journal* — if you
    logged alcohol, a sauna, stress or travel, it downgrades and tells you why ("Probably not illness — you
    logged a few drinks"). It always shows the *why* and what it ruled out, and never names a condition:
    "On-device estimate — not a diagnosis." Toggle under **Settings → Automations → "Illness
    early-warning"**.
- **Your Data, Fused — one honest record across your bands.** If you wear more than one device — a WHOOP
  plus a Mi Band, plus Apple Health / Health Connect — NOOP now fuses them into one record **on your
  device**, picking the best source per metric (the band that *counts* steps beats the strap's estimate; the
  better stager wins for sleep), naming the source on every number, and **flagging disagreement instead of
  silently averaging it** ("Sleep 7h 12m · from WHOOP · ⚠ Apple Health says 6h 40m — tap to compare"). It
  never claims a number is "correct" — only best-sourced and fully transparent. A single-WHOOP setup just
  shows a clean plain record. Open **Your Data, Fused** from **Health** or Data Sources. The privacy-first
  inverse of a cloud aggregator: nothing leaves the device.
- **Lab Book — your own private health logbook.** A place to keep the numbers you already own — bloods,
  blood pressure, scan values, body measurements, doctor's-visit notes — typed in by hand or imported from a
  CSV, and lined up against your wearable signals. Each marker shows its trend; **"Compare with a signal"**
  lines a marker (say LDL) up against resting HR, HRV, sleep or Charge over a 7/14/30-day window, with the
  same restrained "tends to" language used elsewhere. The framing is load-bearing and non-negotiable: **Lab
  Book is a private notebook, not a medical service.** NOOP *stores and lines up the numbers you enter
  yourself* — it does **not** test you, read your results, decide whether a value is "normal/high/low", or
  diagnose anything; any reference range shown is exactly what you typed from your own report. Your records
  **never leave your device**; because NOOP is an independent app you run yourself (not a healthcare
  provider) it is **not "HIPAA-covered"** — the protection is that the data is local-only and yours. Always
  rely on your doctor or pharmacist to interpret results. Open **Health → Lab Book**.
- **Rhythm (experimental) — a picture of your beat-to-beat timing.** On *every* strap (4.0 and 5/MG), NOOP
  can draw a **Poincaré scatter** of your beat-to-beat intervals with plain descriptive stats (SD1, SD2,
  the SD1:SD2 ratio) and a calm categorical read — *Rhythm — steady* / *Some occasional extra or skipped
  beats* / *Your rhythm varied more than usual*. **It is a visualisation, not a verdict: not an ECG, not a
  diagnosis, not a medical device, and it cannot detect, rule out or monitor any heart condition.** Variation
  in beat timing is normal and often completely benign. It's **off by default** behind a consent screen you
  must read and tick: **Settings → Rhythm → "Turn on Rhythm"**. No alarms, no red, no condition names — by
  design.
- **A smarter, still-private AI Coach.** The opt-in **bring-your-own-key** Coach can now optionally reason
  over your on-device patterns (recovery drivers, your discovered correlations) and your Lab Book markers —
  and tell you *which* of your numbers it read. The privacy line holds exactly as before: nothing leaves
  until you've added your own key, switched consent on, and asked a question; only a **compact text summary**
  of computed values is sent to the provider *you* chose — never your raw R-R, PPG or motion. Turn the
  deeper context on with **"Also share my patterns & Lab Book"** in Coach (off by default). As always, the
  Coach is the only place NOOP touches AI, it's your key and your choice of provider, and the app stays
  offline everywhere else.

**Honest, as ever.** WHOOP 4.0 is the supported path; deeper 5/MG metrics are still being figured out.
Skin-temp estimates, resonance detection, the haptic-paced wake, and Rhythm are explicitly experimental and
build over a week or two of wear. Nothing here is medical; nothing is a diagnosis; nothing leaves your
device. Internal data keys are unchanged, so years of history and every import keep working. Engines are
unit-tested with Swift↔Kotlin parity locked across macOS, iOS and Android.

---

## 4.9.1 — More realistic calories + import, chart & sideload fixes

- **More realistic daily calories (all platforms).** The all-day energy estimate read high — it
  credited ordinary daytime heart rate at exercise intensity. The gross-exercise rate now only kicks
  in at genuine exertion (≥ 50% heart-rate reserve, up from 30%), so daily burn reads closer to
  reality. Detected/manual workouts are unchanged. (Community-reported.)
- **Health Connect workouts show on the Today graph (Android).** A workout imported from Health
  Connect now gets its marker on the Today heart-rate graph, like recorded and manual workouts.
- **Fixed WHOOP-import day shift (Android).** Importing a WHOOP export could file a night's sleep on
  the wrong day (a day early) and split it across two days — it now keys to the correct wake-day.
- **Honest Smart-alarm wording (iPhone/Mac).** The Smart-alarm card now states up front that a
  strap-driven wake is experimental and unverified on WHOOP 4.0 / 5/MG — keep a backup alarm.
- **iPhone sideload fix.** The AltStore/SideStore source no longer fails with "given data not valid
  JSON" — the install docs and source pointed at the dead GitHub host; they now use noop.fans.

---

## 4.9.0 — Steadier heart rate + a stack of fixes

- **Steadier live heart rate (all platforms).** The Health tab and the macOS menu bar now show the
  same spike-filtered reading as the Live screen, so a one-off optical sensor blip no longer flashes a
  wild number like 170+. (Thanks @ryanbr and @bringiton321 — #39.)
- **Deleted sleep stays deleted (Android).** A sleep session you delete is now recorded with a durable
  tombstone, so it no longer reappears after the next on-device recompute. (Thanks @ryanbr and
  @pikapik487 — #33.)
- **Step calibration finds your phone steps (Android).** Calibration now reads your phone's step count
  from both Apple Health and Health Connect imports — previously it read the wrong store and could miss
  them entirely, leaving you stuck on "Not calibrated". (Thanks @pikapik487 and @bringiton321 — #37.)
- **Homebrew install fixed (macOS).** `brew install` works again — the tap command now points at the
  project's self-hosted home. The old `brew install --cask noopapp/noop/noop` shorthand resolved to a
  host that no longer serves the tap; use `brew tap noopapp/noop https://noop.fans/NoopApp/homebrew-noop
  && brew install --cask noop`. (Thanks @tonyjacked — #44.)

---

## 4.8.0 — On-demand HRV, a haptic clock, sleep marks & more (all platforms)

- **New: take an HRV reading on demand.** An "HRV reading" button on the Live screen captures about 60
  seconds of your heart's beat-to-beat timing and gives you a single RMSSD reading right there — sit
  still, breathe normally, and watch it settle. Saved alongside the rest of your data. (#127.)
- **New: feel the time — Haptic Clock.** Your strap can now buzz out the current time: long buzzes for
  tens, short for units, hours then minutes. On iPhone/Mac, set a strap double-tap to "Buzz the time"
  under Automations; on Android there's a "Buzz the time on your strap" button in Settings →
  Diagnostics. (#460.)
- **New: tap to mark sleep.** Two buttons on the Sleep screen — "Going to sleep" and "I'm awake" — log
  a timestamped mark so you keep your own record of when you turned in and woke up. (#461.)
- **New: scheduled debug export (Android).** Turn on a daily auto-export of your strap log at a time
  you choose, written with timestamped filenames — handy for attaching to a bug report. (Thanks
  @maddognik — #510.)
- **Clearer steps screen on a WHOOP 4.0.** If your strap hasn't synced any motion yet, the Steps
  calibration screen now explains why it's empty — it needs your strap's banked motion history to sync
  first. (Thanks @bringiton321 — #37.)

---

## 4.7.0 — Mi Band import + a big WHOOP 4.0 sleep fix (all platforms)

- **New: import a Xiaomi Mi Band.** Bring a Mi Band / Smart Band 8, 9 or 10's full history — steps,
  heart rate, resting HR, sleep stages + hypnogram, SpO₂, stress and sleep score — straight from the
  Mi Fitness app's on-device database. Fully offline (no Bluetooth, no Xiaomi account). It gets a
  dedicated page and shows up across Explore, Compare and Correlations. (Thanks to @matt — #35.)
- **Fixed: WHOOP 4.0 sleep tracking.** A 4.0 night is rebuilt from "clumped" motion (dense bursts split
  by long dropouts); the detector was shredding those nights at each dropout into fragments it threw
  away — giving ~0 sleep or a night split in half with the wrong start. It now bridges across the
  dropouts (vouched by heart rate) into one correct night. (Thanks @ryanbr — #28, #33.)
- **Fixed:** a workout's calories rendered with a trend arrow that read as a minus sign ("-874 kcal");
  plain magnitudes now show no arrow. (Thanks @Dumbledodge — #41.)
- **Fixed:** tapping a metric in Explore on iPhone no longer flashes the detail and bounces back. (#38.)
- **Cleaner Settings on a WHOOP 4.0** — the 5/MG-only experimental controls are hidden when you're on a
  4.0 (model detected automatically). (#22.)
- **Faster overnight catch-up** — after the phone's been off, a strap that drip-feeds its history drains
  back-to-back instead of stalling between chunks. (#25.)
- **Bounded local storage** — experimental raw-capture buffers are now size-capped. (#27.)
- **Apple Health body composition** — NOOP reads weight, body-fat %, lean mass and BMI on iPhone. (#20.)
- Fixed the misleading "turn on 5/MG raw capture" message a WHOOP 4.0 user could get stuck on. (Thanks
  @ryanbr — #32.)

## 4.6.4 — Round rings (Android)

- **Fixed:** on the new Today screen, the **Effort** ring could render as a squashed oval — the three
  score rings didn't quite fit the row width, so the last one got pinched horizontally. The rings are
  now sized to fit (and the ring component draws a true circle even in a tight box), so all three are
  perfect circles on every screen size. (Android.)

## 4.6.3 — The new Today screen comes to Android

- **Android catch-up.** v4.6.2 brought the WHOOP-style Today hero to iPhone and Mac, but Android only
  got the new ring *style* inside the old layout — so it didn't actually look like the new design. This
  finishes the job: Android now leads with the **three score rings (Charge centred and enlarged, Rest and
  Effort flanking)** over the scenic backdrop, the old big gold recovery ring is gone, the Support heart
  moved to the top bar, and the HRV / Resting HR / Respiratory rows sit just below — matching iOS & macOS.
  (Android only; iPhone and Mac were already on this layout in 4.6.2.) Thanks to the folks on Reddit who
  flagged that Android still looked different.

## 4.6.2 — A bolder Today screen (all platforms)

- **The Today scores got a glow-up.** Charge, Effort and Rest now ride on crisp, full-circle gauges
  that sweep in and count up — a cleaner, bolder at-a-glance read on iPhone and Android. (Thanks to
  @unruffled688 for the iOS redesign — #23.)
- **Fixed:** the **Releases** links in the README and docs pointed at a path that 404'd on the new
  home — they now go straight to the downloads page. (#26)

## 4.6.1 — NOOP has a new home (all platforms)

- **NOOP now lives at [noop.fans](https://noop.fans/NoopApp/noop).** After the project's GitHub was
  taken offline, NOOP moved to its own independent home — code, releases, the wiki and issues.
  **Settings → About** now links straight there, and **Check for updates** reads from the new home (if
  GitHub ever comes back it will be kept as a mirror). Nothing on your device changed and everything
  keeps working — this just points the app at where the project lives now. Keeping it online costs
  real money, so if NOOP is useful to you, please consider a donation. #KeepNOOPAlive

## 4.6.0 — Editable naps, richer Trends report, better debug export (all platforms)

- **#508 — editable + manually-addable naps.** Generalised the durable sleep-edit mechanism (PR #395: userEdited flag + recompute overlap guard + immutable detected startTs PK + re-stage-from-raw) to nap-type sessions, rather than building a parallel system. You can now edit a detected nap's start/end (re-staged from raw over the corrected window, sticks through re-syncs) and manually add a missed nap, from the Sleep screen. Naps are always their own session — never folded into main sleep — so the awake daytime between them is no longer mislabelled as light sleep. The SleepStager detection/classification was NOT touched. Swift (MetricsCache.insertManualSleepSession + Repository.addManualNap + SleepView naps card) + Android (DAO insert, WhoopRepository.addManualNap, SleepScreen add-nap flow), with new tests on both. *(Note: a manually-added nap shows as its own session and is protected by the overlap guard, but its minutes are not yet folded into the day's dashboard Rest/total-sleep rollup — that touches the scoring loop and is a follow-up.)*
- **#457 — Workouts + Stress rows in the Trends report.** Two new `ReportMetric` rows lead the exportable report (Workouts before Stress): Workouts = activity count/day (valence-free), Stress = the 0–3 daily autonomic-load index (calmer is better), each with the existing measured-vs-computed legend treatment. Stress is read from the stored `my-whoop`/`stress` series (no fabrication when a day has none). Swift + Android engine + view, 3 new RangeReport tests.
- **#510 — better on-device debug export.** Rolling strap-log buffer raised from ~1h (200/2000 lines) to a rolling 24h (5000 lines, bounded <~1 MB); exported strap logs and raw captures get a `yyMMdd-HHmm` timestamp in the filename so successive shares don't overwrite; new one-tap **"Export raw + log"** that hands over the raw capture and the matching strap log as a pair. Swift + Android.

## 4.5.5 — Today's Effort no longer drops to zero (all platforms)

- **#489 / #506 — the Today Effort gauge could briefly show the correct value, then fall to 0.** The live in-progress Effort (recomputed over today's raw heart rate, midnight→now) can UNDER-read — on a WHOOP 5/MG with sparse HR, or when a logged workout's load isn't in the raw stream — and it was preferred over the day's stored Effort whenever it was non-nil, so it replaced a real value (e.g. a genuine 38.3 after a morning workout) with a live 0. The Today gauge now floors the live value at the day's already-earned Effort (`max(live, stored)`); Effort accrues over a day and must never visibly drop. Safe by construction: `displayDay`/`displayMetric` for today is always today's row (or nil), never a prior day, so this can't resurrect a stale day. Swift + Android.
- **#509 — the strap log is now reachable from Settings on iPhone too** (it was macOS-only in 4.5.4). Settings → Strap → Copy / Save, building the same text as the Live screen's log card (`LiveState.exportableLogText()`).

## 4.5.4 — Find your strap log in Settings (macOS)

- **macOS: a Strap log shortcut in Settings.** The strap log — the thing the maintainer needs when you report a bug — lived only on the Live screen, and people kept hunting for it (#507, #17). It's now also in **Settings → Strap**, with **Copy** and **Save…**, building the exact same text as the Live screen's log card (shared via `LiveState.exportableLogText()`, so the two can't drift). No behaviour change beyond the new shortcut; iPhone and Android are unchanged (Android already had it in Settings).

## 4.5.3 — Sleep fix for WHOOP 4.0 + accurate WHOOP 5/MG steps (all platforms)

- **#507 REGRESSION FIX — the off-wrist guard no longer drops real WHOOP 4.0 nights.** The v4.5.0 off-wrist guard treats a long heart-rate gap as a proxy for the strap being off the wrist. But a WHOOP 4.0's *synced* night is reconstructed mostly from motion with sparse, derived heart-rate — so a real 4.0 night is naturally full of >20-min HR gaps, which the guard read as ~100% off-wrist and dropped the whole night. The HR-gap proxy is now gated on **HR density**: it only fires when the stream averages at least one sample per `hrDenseSpacingS` (10 min), measured over the whole window so a genuine off-wrist *hole* in an otherwise dense, worn day (#500) is still caught. Self-consistent — a night sparse enough to be falsely >50%-covered is, by definition, below the density floor, so it's spared. Explicit `WRIST_OFF` events remain authoritative regardless of density. Swift + Android, with a "sparse-HR real night is kept" test on both. Thanks @Mindfulpaths (#507).
- **WHOOP 5/MG steps are now accurate (#276 / #316).** The firmware's motion/step field at byte `@57` is the LOW byte of a **cumulative 16-bit counter** at `[57:59]` — reading the byte alone and summing it across records over-counted steps many times over (~24×). NOOP now reads the full little-endian `u16` and sums only the **wrap-aware increments** (`(cur − prev) & 0xFFFF`, dropping deltas ≥ 512 as sync-gap boundaries), so the daily total is sane. It also decodes the per-record **activity class** at `@63` (0 = still / 1 = walk / 2 = run) — a lightweight, no-cloud activity signal. Swift + Android, with over-count / wrap-around / jump-guard tests. Thanks @j0b-dev for the frame analysis.

## 4.5.2 — Honest labelling for WHOOP 5/MG deep-data diagnostics (all platforms)

- **Corrected the experimental R22 "deep data" telemetry wording (#494).** The diagnostic used to announce *"Deep data is flowing — N R22 packets this session. Please share your strap log!"* (green, celebratory) when it saw `type-0x2F` frames outside our own history sync. #494 established those frames are **historical-offload data** — typically a SECOND BLE client pulling the strap's backlog over the shared notify channel (the burst scales with backlog time, not wall-clock) — and that the `enable_r22_*` SET_CONFIG sequence (accepted 15/15) starts **no** separate live stream; `type-0x2F` is only ever the historical offload (confirmed across #344's v20/v21 captures too). The counter, the strap-log lines, and the Settings text now describe them accurately as historical-offload frames rather than a live-stream "unlock", so nobody is sent chasing a stream that isn't there. **Purely a labelling/doc change — no behaviour difference** (the flag-ACK counting and the trailing-offload cooldown are untouched). Swift + Android. Thanks to community contributor **j0b-dev** (PR #505); reimplemented here as project work.

## 4.5.1 — Sleep: keep real nights when the strap comes off (all platforms)

- **Refinement to v4.5.0's off-wrist sleep guard (#500, #504).** v4.5.0 dropped a detected sleep block on *any* off-wrist signal (a >20-min HR gap or a single `WRIST_OFF` event inside it), which could discard a genuine night whose detection over-extended into a short off-wrist morning tail (strap removed shortly after waking). The guard is now **fractional**: a block is rejected only when its off-wrist coverage — the union of HR-gap spans (≥20 min) and `WRIST_OFF`→`WRIST_ON` intervals, clipped to the block and merged so overlaps count once — is **≥ 50%** of its duration. A real night with a small off-wrist tail (or a brief mid-night blip) is kept in full; an all-day desk strap (~100% off-wrist) is still ignored. Swift + Android, with tests covering the survives-short-tail case both via HR-gap and explicit-interval paths. Thanks to community contributor **j0b-dev** for the sharper fractional approach (PR #504); reimplemented here as project work.

## 4.5.0 — WHOOP 5/MG deep-sync decode + sleep & workout fixes (all platforms)

- **WHOOP 5/MG historical decode — v20/v21 layouts + richer v18 fields (#344).** Newer 5/MG firmware banks some nights in record layouts NOOP didn't map yet (internally "v20" and "v21"); they were failing the unrecognised-layout path and surfacing as empty nights. Those now decode to timestamps + optical/motion channels, so more 5/MG history syncs through. We also extract additional fields from the existing v18 records (per-record index, higher-precision HR, step cadence, an auxiliary thermal channel, status/sleep-state bitfields) and corrected the skin-temperature scale from /128 to /100 (a worn strap now reads ~30.6 °C instead of an impossible ~22 °C). All offsets were validated against real captured frames and CRC32 integrity; the Swift WhoopProtocol suite is at 164 passing tests. Thanks to community contributor **j0b-dev** for the captured-frame analysis (reimplemented here as project work).
- **Sleep: off-wrist daytime no longer logged as sleep (#500).** The daytime false-sleep guard now rejects any candidate sleep run that has a long contiguous heart-rate gap (>20 min — a strong off-wrist proxy that works even when the strap emits no explicit marker) or that overlaps a `WRIST_OFF` event. Time on the charger or sat still at a desk is no longer counted as a nap, day or night. The guard never trips on a worn, gap-free night (verified by the existing real-night test suites staying green).
- **Sleep: wake time no longer clamped to 6 PM (#500).** Past nights whose real wake was later than the read-window edge were truncated to exactly 18:00. Past days now read through to the next local midnight so the stager sees the whole night and reports your true wake.
- **Workouts: Average HR always matches the recorded trace (#499).** A strap-tracked workout's Average (and Max) HR is now always derived at display time from the exact per-second samples that drive the graph, the zones, and the effort score — they can no longer diverge from a stale or hand-edited value. Imported workouts (Apple Health / Health Connect / CSV) keep their own averages.
- Fixed a Swift build warning (#496) and repaired the macOS (Homebrew) and iOS (AltStore/SideStore) download links for the 4.4.0 release, which pointed at mis-named assets.

## 4.4.0 — Classic chart colours: a throwback toggle (all platforms)

- **A new Chart-colours toggle re-skins every gauge, ring, chart and scale to the traditional red → amber → green readiness palette** — the colourful style people know. **Settings → Appearance → Chart colours**: **Titanium** (the brand gold/amber/blue ramps, the default) or **Classic**. Classic re-colours the *data* — recovery red→green, HR zones cool→hot, stress green→red, a purple REM sleep band — and leaves the app's chrome (surfaces, text, buttons) untouched. Works in **both Light and Dark**. Architecture: the data-ramp accessors in the palette branch on the chart style (a global on Apple, snapshot state on Android), so one toggle re-colours every chart with no per-screen rework. Nothing about your numbers changes — only how they're coloured.

## 4.3.2 — Light theme tuning (all platforms)

- **Light got dialled in, from early feedback that it leaned too gold.** The *chrome* — links, the selected range pill, header accents — now uses the deep brand **blue** on Light, with **gold reserved for what it means** (the Charge/recovery rings and the action button). Cards sit on a slightly **deeper warm canvas with a stronger drop shadow**, so they stand out more clearly. On **macOS**, a sidebar glitch where the NOOP lockup overlapped the navigation list is fixed (it's now a proper fixed header above the list). **Dark is unchanged.**

## 4.3.1 — Light theme polish (all platforms)

- **A theme audit caught a handful of details that were tuned for dark and read faintly (or invisibly) on the new Light theme** — a few chart/gauge end-cap dots (the white core vanished against the white card), a secondary-button outline, and a tooltip shadow. They now flip to the right ink/shadow on Light via the same dynamic tokens. **Dark is unaffected.** If you tried Light in 4.3.0 and saw a missing dot at the end of a graph line, this fixes it.

## 4.3.0 — Light theme: NOOP in warm paper & gold (all platforms)

- **NOOP now has a full Light theme, switchable any time.** Settings → Appearance offers **System** (follow your phone/Mac), **Light**, or **Dark**. The new Light look is "warm paper & gold" — a soft warm-white canvas with crisp navy-ink text and the brand gold deepened so it stays legible on white. Every surface was re-done for it rather than inverted: the ring gauges, the frosted cards (lifted with a soft drop shadow instead of a glow), the charts, the scenic hero, the home-screen / Dynamic Island widgets and the status bar all adapt. **Dark is unchanged.** Architecture note for the curious: on Apple every palette token became a dynamic `Color(light:dark:)`, and on Android a snapshot-state token set behind the `Palette` facade — so the whole UI re-resolves from one toggle with no per-screen rework.

## 4.2.13 — Effort explains a calm-day zero — and scores on the 5.0/MG (all platforms)

- **Effort now explains a calm-day zero instead of just showing "0.0".** Effort is *cardiovascular* load — it only builds while your heart rate is up in your effort zone (roughly the top half of your heart-rate reserve, often ~120 bpm and above). On a genuinely easy day your heart rate never gets there, so the honest answer really is near zero — the same way a WHOOP low-strain day reads low. The number was right, but a bare "0.0" looked broken, so Today now adds a short line explaining it. We also fixed the **WHOOP 5.0/MG** case where Effort could sit un-scored for hours: the 5.0/MG sends live heart rate far less often than a 4.0, and the gauge needed a fixed *number* of readings before it would score — now it scores once it has enough *time* of heart-rate coverage, so a steady 5.0/MG stream counts and the gauge stops falling back to a stale value. Effort still only rewards real exertion — nothing is invented. Thanks **@darylbleach** and **@phsycology** (#482, #480).
- **History from a long-drained strap lands on the right day again.** When a WHOOP's internal clock had fully reset — it sat uncharged so long its clock fell back to around 1970 — syncing its stored history could date every night decades into the future, silently wiping sleep and recovery from your timeline. NOOP now keeps the real timestamps in that case. Thanks **@cataboysbusiness-debug** (#471).

## 4.2.12 — Fix: app crashing / won't open when Bluetooth is on (Android)

- **Fixed NOOP crashing — or refusing to open at all — whenever Bluetooth was on**, which hit some phones hard (notably WHOOP 5.0 / MG on Android 16). When Bluetooth came on, NOOP's background service reconnected to your saved strap and logged the first frame it received; a bug in the privacy log-redaction code (it masks Bluetooth addresses) threw an error on that line and **crashed the entire app — even while it was closed**, and the bug was in earlier builds too, so downgrading didn't help. Two fixes: the redaction bug itself is gone, and the **logging path is now hardened so a diagnostic line can never crash the app again** (belt-and-suspenders, with a regression test). Your data and history were never at risk. Huge thanks to **@frazzle28** and **@pawan0305** for the reports and the crash trace (#453). *(Android — macOS/iOS use a different, unaffected redaction path.)*

## 4.2.11 — Polar H10 & other heart-rate straps connect again (Android fix)

- **Fixed a crash that stopped Polar H10 and other standard Bluetooth heart-rate straps from connecting on Android.** When NOOP went to activate a generic HR strap, an internal log-redaction bug threw an error the instant it wrote the strap's Bluetooth address into the strap log — and that thrown error quietly aborted the connection, so the strap paired but never streamed live data. The strap now connects and streams as intended. **WHOOP straps were never affected** (they only ever log a `<serial>`, never a raw address, so the bug stayed hidden until a generic strap was used). Added a unit test so it can't regress. Thanks **@pilleuspulcher-blip** for the strap log that pinned it (#421). *(Android only — macOS/iOS were never affected; they stay on 4.2.10.)*

## 4.2.10 — Week in Review is honest about a half-finished week (all platforms)

- The **Week in Review** summary no longer says "a steady week — nothing moved" when you're only **a day or two into the week**. Early on, NOOP genuinely can't call a week-over-week trend — but the summary used to claim a steady week while the change chips right above it showed big percentage swings off those same one or two days, which read as a contradiction. Now a sparse current week says something like *"Only 2 days into this week so far — too early to call a week-over-week trend yet,"* matching what the chips can and can't tell you. A full week with genuinely flat metrics still reads as steady. Thanks **@pikapik487** (#463).

## 4.2.9 — Respiratory rate & skin temperature in the Trends report (all platforms)

- The shareable Trends report (**Trends → Export**) now includes **Respiratory rate** and **Skin temperature** — two more rows measured from the strap, alongside HRV, Resting HR, Sleep, Recovery and Strain. Each shows its average, min/max with the day it fell on, daily trend and a per-day sparkline over the window you pick. Respiratory rate treats a **rising** trend as *"worth a look"* (a higher resting breathing rate can signal illness or strain — lower is the calmer read). **Skin temperature is shown as the signed deviation from your own baseline** (e.g. `+0.3 °C`), and deliberately carries **no good/bad verdict** — a move in either direction can matter, so the report states the direction and lets you read it. The "How to read this" legend now lists both as measured. Thanks @subscriptiondestroyer (#457). *(Workouts and stress in the report are still tracked as the next follow-ups.)*

## 4.2.8 — Double-tap to log a sleep mark (iPhone & Mac, experimental)

- A new double-tap action: **"Log a sleep mark."** Set it under **Settings → Automations** (the strap double-tap action), and a double-tap on your band writes a timestamped `Sleep mark @ 23:42` line into your strap log — with a single confirming buzz — so you can mark bedtime, wake, or a mid-night wake with no screenshots and nothing to remember. The marks ride along in your shareable strap log. This is **Phase 1** (just capturing the marks) — the foundation for tap-driven sleep bounds and personal sleep-stage calibration down the line. Thanks @maddognik for the idea (#461). *(iPhone & Mac first; Android to follow — its strap double-tap doesn't yet have a configurable action.)*

## 4.2.7 — Start a workout from the Workouts screen (iPhone & Mac)

- You can now **start a live workout straight from the Workouts screen** (reached from the centre "+" quick-action or the Workouts tab), not only from the Live screen. A prominent **Start Workout** button begins the session and opens the in-exercise view right away; if one's already running it becomes **View active workout**. This is where people instinctively look for it. Thanks @subscriptiondestroyer (#459). *(iPhone & Mac catching up — Android already had a start control on its Workouts screen.)*

## 4.2.6 — "Now" dot sits on the trend line (iPhone & Mac)

- Fixed the glowing "now" dot on the Trends graphs (Charge, HRV, Resting HR, Effort) floating *below* or *to the left* of the line instead of landing on the latest point. The dot was positioned by guessing the chart's plot margins; it's now placed using the chart's own coordinate system — the same mapping the line uses — so it sits exactly on the curve's final point. Thanks @subscriptiondestroyer (#458). *(iPhone & Mac; Android's trend charts position the dot correctly already.)*

## 4.2.5 — Trends report explains its scores (all platforms)

- The shareable Trends report now carries a **"How to read this"** legend, so it's clearer when you hand the PDF to a doctor, coach or friend: HRV, Resting HR and Sleep duration are flagged as **measured** from the strap, while **Recovery and Strain are spelled out as NOOP's own on-device scores (not clinical measures)** — Recovery as a daily readiness composite, Strain as cardiovascular load from heart rate. The numbers stay (they're still useful as your own trend); now nobody reading it has to guess which are measured vs. computed, or how. Thanks @subscriptiondestroyer (#457). *(Adding workouts, stress and extra vitals like respiratory rate and skin temp to the report is tracked as a follow-up.)*

## 4.2.4 — Trends report export now opens the share sheet on iPhone (iOS fix)

- Fixed the **Export PDF** button on the Trends report doing nothing on iPhone. The report opens in a sheet, but the share sheet was being presented from the wrong place (behind the report that was already on screen), so iOS silently dropped it and the export appeared to fail. NOOP now presents the share sheet from the top-most screen, so it slides up correctly and you can save the PDF to Files, AirDrop it, or send it on. Thanks @subscriptiondestroyer (#455). *(iOS-only fix — the macOS and Android exports were unaffected; they're functionally unchanged in this release.)*

## 4.2.3 — Deep history backlog drains without manual strap taps (all platforms)

- Fixed a sync stall where a strap that had been fully discharged (or carried a previous owner's history) would offload only one night per connection and then sit idle until you physically tapped the strap to force the next chunk. The cause: such a strap banks records across multiple clock epochs, and the "newest record" the strap reports can latch a stale value (e.g. a 2024 timestamp when your real newest is 2026) — which read as *behind* what NOOP had already saved, so the auto-continue logic wrongly concluded "caught up" and stopped. NOOP now also checks whether the just-finished pass actually handed over real sensor rows: if it did and the strap's trim cursor advanced, the backlog keeps draining in back-to-back passes regardless of a stale "newest" reading. A genuinely caught-up strap still stops (it persists zero new rows), and the per-connection cap still bounds it. Thanks @claypilat for the precise diagnosis (#451) — this also removes the "have to keep re-triggering it" half of #364.
- Sync diagnostics now log the strap's full banked-history span (oldest → newest, with an approximate day count) so a deep multi-epoch backlog is visible at a glance in the strap log.

## 4.2.2 — Sleep stages heal themselves after a sync (all platforms)

- Fixed a bug where editing a night's wake time *before* the strap finished importing that window's raw data produced a wrong stage breakdown that then stayed frozen forever. Stages now re-derive from the real data the moment it arrives — affected nights heal automatically on the next sync — while your bed/wake correction stays locked. Decoupled the user-edit lock from the (re-derivable) stage breakdown; made the stored stage JSON deterministic so the heal is a clean no-op once steady. Thanks @claypilat (#449). *(Shipped first on macOS + iOS; Android brought to parity in the same 4.2.2 — the Android stage-JSON encoder was also made deterministic, which it wasn't before.)*

## 4.2.1 — Optional inactivity nudge

- An opt-in move reminder: NOOP can buzz your strap after you've been sitting still too long (your threshold, default 45 min), within active hours you choose, with a re-nudge cooldown. Off by default, runs from the motion already on your strap, respects quiet hours and only-when-worn. Settings → Automations. Thanks @cbarrado (#419).

## 4.2.0 — Open a workout, see what it costs you, and share your trends

- Tap any workout to open a full detail view — HR curve over the session, time in each HR zone, duration, avg/max HR, and the Effort it added (#410).
- Activity Cost: a new Insights section correlates your tagged activities with the next morning's Charge — the typical cost and days-to-baseline, measured against your own untouched rest-day baseline, gated by a confidence level (#439).
- Shareable trends report: export a one-page PDF of recovery, sleep, HRV, resting HR and strain over a chosen range, entirely on-device via the system share sheet (#436).
- Last night syncs sooner — a deep backlog now keeps draining while you're connected instead of waiting 15 minutes between bursts, plus a "Sync now" button to backfill on demand (#364).
- Weight imported from Health Connect now resolves in Compare (Android), where a HC-only weight history was previously invisible (#443).
- Docs: recorded the FORCE_TRIM / REBOOT_STRAP destructive-command payload forms as known-and-avoidable (NOOP never sends them) (#444). The published Android **demo** APK is retired — the demo flavour stays build-from-source only.

## 4.1.1 — Android hotfix

- Fixed a crash introduced in 4.1.0: making a generic heart-rate strap active could crash the app, and because that strap stays the active source it recurred on every launch. Activating a strap can no longer take the app down (#421). Android only.

## 4.1.0 — Estimated steps for your WHOOP 4.0

- Steps on a WHOOP 4.0 are now ESTIMATED from the strap's motion and calibrated to your own phone step count (Apple Health / Health Connect) — an honest estimate (shown with an "est." marker, never a pretend pedometer), with a calibration screen (Settings → Profile → Steps estimate) showing estimate-vs-phone and a manual tuning dial. A real phone step count always wins; the estimate only fills uncovered days. (#276/#316/#303/#442/#409)
- Generic heart-rate straps (Polar/Wahoo/Coospo) now actually CONNECT when made active — they were being discovered but never connected to, so they showed no live data (#421). And the strap log no longer exposes your WHOOP serial or Bluetooth MAC addresses — masked automatically so it's safe to share (#445).

---

## 4.0.4 — Sync visibility & a sharper Stress timeline

- Sync diagnostics: the strap log now shows the newest record your band actually holds, so a "last night didn't sync" report tells us whether the night is banked-but-not-yet-reached vs genuinely not on the strap. Thanks @idkwargwanbear (#364).
- Android: the Today stress timeline gets a Y-axis + tap-to-read. Thanks @ujix (#441).

---

## 4.0.3 — Date fixes, UI polish & clearer diagnostics

- **Today's date now matches Intelligence History.** On Android, the Today/Recovery screen could label a
  day with one date while showing the previous day's numbers (when this morning's recovery wasn't scored
  yet), so it disagreed with the same day in Intelligence History. The Today date now names the row
  actually on screen — matching Intelligence and the Mac/iPhone behaviour. Thanks @pikapik487 (#434).
- **Clearer diagnostics for non-WHOOP heart-rate straps.** Connecting a generic strap (Polar, Wahoo,
  Coospo…) now records every step of the Bluetooth handshake in the strap log — scan, connect, service
  discovery, notification enable, first reading — so a "connected but no data" report can actually be
  diagnosed instead of showing only WHOOP activity. Adds a single auto-retry on the common Android `133`
  connect error. Thanks @pilleuspulcher-blip (#421).
- **UI polish (Android):** the "vs previous month" comparison in Explore no longer clips; the bedtime/wake
  time-scale label isn't cut off; the Insights day order is now Yesterday → Today → Tomorrow; and the
  "Journal" heading stays on one line. Thanks @nhe (#443).

---

## 4.0.2 — Switching between WHOOP straps now actually switches

- **Multi-WHOOP: switching the active strap now moves the connection to it.** With more than one WHOOP
  paired, switching the active one could leave the app streaming the *previous* strap while showing the
  new one — on reconnect it re-attached to whatever the system already had open instead of the strap you
  selected. It now drops the old strap and connects to the one you picked (Mac & iPhone), and the WHOOP
  5/MG bonded fast-path on Android honours your selection the same way. Single-WHOOP setups are unaffected.

---

## 4.0.1 — Today's Effort goes live, plus sleep & alarm honesty

A fix release following a full code review of the v4 line.

- **Today's Effort now updates live through the day.** The Effort ring recomputes over today's heart rate
  as it happens (midnight → now), instead of showing yesterday's completed-day value — or a stale 0.0 early
  in the morning — until the next full re-score. Thanks @rad182 ([#402](https://noop.fans/NoopApp/noop/issues/402)).
- **Editing a sleep time can't scramble the night any more.** The wake picker keeps the night on its own
  day, so correcting a bed/wake time re-derives that night's stages cleanly instead of splitting the
  corrected block and its totals across two days. Resting-HR + HRV day-bucketing was also aligned across
  Mac, iPhone and Android. Thanks @ujix ([#406](https://noop.fans/NoopApp/noop/issues/406)).
- **Late nights and long lie-ins are captured** — the sleep-detection window was widened so a wake after
  noon isn't cut short. Thanks @ujix ([#425](https://noop.fans/NoopApp/noop/pull/425)).
- **Smart alarm is now honestly flagged experimental.** The strap acknowledges the alarm, but a
  strap-driven wake hasn't been verified firing yet — on WHOOP 4.0 *or* 5/MG — so the app asks you to keep
  a backup alarm while we confirm the exact firmware buzz pattern. Thanks Kaliarti ([#428](https://noop.fans/NoopApp/noop/issues/428)).
- **Android: rename your WHOOP's Bluetooth name** — brings Android up to the iPhone/Mac feature. Thanks
  @cbarrado ([#422](https://noop.fans/NoopApp/noop/pull/422)).
- **Polish from the review:** your Vitality breakdown now reconciles exactly with the Body Age number it
  explains; the new Age cards always compute on Android (the age control is bounded like iPhone/Mac);
  renaming no longer spins forever if your strap doesn't answer; live workout detection now covers the
  whole calendar day. Thanks @rad182, @cbarrado, @j0b-dev.

---

## 4.0.0 — Your Fitness Age, Vitality and Body Age

NOOP's new **Age & Longevity engine** — the headline of v4. Three new on-device numbers, all computed
from data you already have, all framed honestly as wellness estimates rather than clinical/biological ages.

- **Fitness Age.** A weekly estimate of how fit your heart is versus your calendar age, from your resting
  heart rate and recent activity, using the published Nes/HUNT non-exercise VO₂max model (waist-circumference
  variant; reproduced in JAHA 2020 / corroborated by CERG). The headline number cancels out body size, so it
  needs nothing but your age, sex, resting HR and activity coverage; a **"How accurate is this?"** checklist
  shows exactly which inputs went in, grouped by what each unlocks. ±5-yr band, never a biological age.
- **Vitality + Body Age.** A weekly **0–100 Vitality** score and a **Body Age in years**, built the way
  WHOOP's Healthspan is — each wearable input (resting HR, sleep duration + regularity, HRV vs the age norm,
  activity) weighed against published all-cause-mortality hazard ratios, overlap-corrected, and converted to a
  years-of-aging offset via the Gompertz "~8 years per doubling" rule. Surfaces the single factor **helping most**
  and the one **holding you back**. A wellness trend, gated on a minimum of inputs — **not** a clinical or
  medical age. (Hazard coefficients are conservative published values; refined over time.)
- **Optional estimated VO₂max.** Add an optional waist measurement in Settings to also see an estimated VO₂max
  beside your Fitness Age (the Fitness Age itself never needs it).
- All three are computed weekly on-device (keyed to each week's Saturday), appear on the Health tab and in the
  metric Explorer + trend charts, and stay entirely offline. Engines are unit-tested with parity locked between
  the macOS/iOS and Android implementations.

---

## 3.9.1 — A round of fixes: reconnect, exports and Health setup

- **Mac & iPhone reconnect on their own.** If your strap briefly dropped out of range, or a connection attempt failed mid-handshake (a weak-signal encrypted handshake on a 5/MG at the edge of range), the app used to sit idle until you reconnected by hand — the disconnect path rescheduled a rescan, but the failed-connect path never did. It now retries on its own with a capped exponential back-off (3s → 6s → 12s … up to 60s) and stops the instant it reconnects. macOS/iOS. Thanks @phsycology (#414).
- **Android: GPS workouts write back to Health Connect.** Workouts tracked in NOOP weren't being saved to Health Connect — the `WRITE_EXERCISE` / `WRITE_DISTANCE` permissions were never declared in the manifest, so the runtime request was silently dropped and nothing was written. Declared them and broadened the writeback gate; existing vitals-only writeback users are re-prompted once for exercise + distance. Thanks @andreasc1 (#412).
- **Raw sensor export no longer runs out of memory.** The experimental raw-sensor CSV export built the entire file in memory (and then a second full copy) before writing, which could OOM on a busy 24-hour window. Both the Android and Mac/iOS exporters now stream rows straight to the file through a buffer, holding only the data itself. Thanks @maddognik (#406).
- **Android: sleep stage breakdown reads cleanly.** Stage-breakdown values under the sleep chart no longer wrap onto a second line and clip against the card edge (#406).
- **WHOOP 4.0: no phantom deep-data counter.** The experimental deep-data (R22) packet counter is a WHOOP 5/MG concept; it no longer increments on a WHOOP 4.0, where a type-0x2F frame means something else (#346).
- **Protocol reference: 5-class (MAVERICK) command numbers** documented in `docs/PROTOCOL.md` and the protocol schema (`SEND_EVENT_PACKETS`, `SET_AFE_PARAMETERS`, `GET_AFE_PARAMETERS`, plus the MAVERICK clock renumbering). Reference only — NOOP does not send these. Thanks @j0b-dev (#418).

---

## 3.9.0 — Manage several WHOOP straps, and see what each band does

- **Manage several WHOOP straps.** If you own more than one WHOOP — a couple of 4.0s, a 5.0, or a mix — NOOP now tells them apart and lets you **pair, switch, rename and remove** each one from the **Devices** screen. Each strap is identified by its own Bluetooth identity, only one is ever active at a time, and your history is never mixed between devices. Cross-platform (iPhone, Mac, Android); the Android device database migrates cleanly from 3.8.0 (emulator-verified).
- **A guided "Add a device" wizard.** Adding a device now **asks what you're adding** — WHOOP 5.0/MG, WHOOP 4.0, or a heart-rate strap — and gives the right pairing steps for that band (a 5/MG pairs differently from a 4.0), then scans the right transport. Coming-soon device types (Garmin, Amazfit/Zepp, Oura/Fitbit import) are shown on the roadmap.
- **The Live screen links to Devices.** The live console now names the **active band** and has a **Manage devices** shortcut, so it's obvious where to pair or switch straps.
- **Honest per-device capabilities.** Each device card now shows **what that band captures and what NOOP uses it for**, per model — so it's clear a 5/MG reports steps while a 4.0 doesn't, and a heart-rate strap drives live HR + Effort only. We also corrected misleading labels: no "Blood oxygen" where NOOP can't read an SpO₂ percentage off the strap (it never can — that only comes from a WHOOP CSV import), and skin temp / respiration are marked as the on-device estimates they are.

---

## 3.8.0 — Connect a heart-rate strap (early access)

- **A new Devices screen — NOOP reads more than just WHOOP now.** Pair a **standard Bluetooth heart-rate strap** (Polar, Wahoo, Coospo, a Garmin HRM, or the Amazfit Helio's HR broadcast) for **live heart rate + HRV**. The new **Devices** screen (System group) lists what's paired, lets you switch which strap is active, rename, or remove one (with a separate, deliberate "delete this device's data" path). Built on a device registry + a per-day source-ownership rule so **only one strap is ever active at a time and NOOP never mixes or double-counts data from two devices**.
- **WHOOP stays the priority.** It remains the primary, fully-supported band; other straps are an early, opt-in addition that stream live HR + HRV only (not WHOOP's deeper sleep/recovery/strain). The generic-strap path is fully isolated from the WHOOP BLE path — with no strap paired, behaviour is byte-identical to before, so WHOOP users are completely unaffected.
- **Early and experimental.** This is the first build that talks to non-WHOOP straps; the live connection is still being proven on real hardware. The Devices screen, pairing flow and data isolation are verified (and the iPhone/Mac screen is render-checked), but the live radio handshake needs real straps to confirm — pair one and let us know. Cross-platform (iPhone, Mac, Android).

---

## 3.7.1 — Tidier Today gauges

- **iPhone/Mac — Today gauges no longer squish (#403):** on larger iPhones the three **Charge / Effort / Rest** synthesis rings rendered cramped, with each ring's state word (LOW / MODERATE / PEAK) overflowing the arc and colliding with the number. Each ring now sizes to its actual card width (with its line width scaling to match), and the state word scales with the ring — pinned to its original size on the big single-score rings (byte-identical there) and shrinking only on the small three-up rings, while keeping Dynamic-Type accessibility scaling. Android's gauges were already responsive, so this is an iPhone/Mac fix. Thanks @claypilat.
- **Under the hood:** groundwork for connecting more than one device (a device registry + single-active rule + per-day source ownership), shipped behaviour-neutral — no change to your current WHOOP setup. WHOOP support remains the priority.

---

## 3.7.0 — A round of fixes: steps, Insights & Health setup

- **Step calibration goes further (#132):** on a WHOOP 5/MG the strap's motion counter can over-report steps by 20× or more, and the per-user calibration divider used to stop at 4×. It now goes all the way to **30×**, and the +/− control uses a variable increment (fine around the 1.0 default, coarser up in the 20s) so a large correction takes a few taps instead of dozens. Floor stays 0.5×; same on iPhone, Mac and Android. Thanks @exzanimo.
- **Insights “By Day” stays smooth with a large history (#345):** tapping **All** with a big imported history used to build every day card up-front, which could freeze the app (and trip Android's "close the app?" prompt). The day list now renders lazily — only what's on screen — so it scrolls smoothly regardless of how many days you've imported. Small histories are byte-for-byte unchanged. (No data was ever at risk during the old freeze — that screen only reads already-stored days.) Thanks @maddognik. While here, the Stress maths were re-checked end to end: the daily monitor (today vs your 30-day baseline) and the intraday timeline (each hour vs that day's calm hours) are deliberately different references, so they read differently — no calculation bug.
- **Honest Apple Health guidance on free sideloads (iPhone, #348):** a build installed with a free Apple ID (AltStore / Sideloadly) is re-signed without Apple's HealthKit entitlement, so it can never appear under Settings › Health › Data Access & Devices. NOOP now detects that and stops giving the impossible instruction — it explains the limitation plainly and routes you to the file-import / Shortcuts path instead. Properly-signed installs behave exactly as before. Thanks @exzanimo.
- **Better odds of unlocking newer straps (#344):** the on-device archive that collects undecoded history frames (the raw material for reverse-engineering new firmware layouts) had a size cap that, once full, dropped new frames indiscriminately — so a rare never-seen layout could be evicted by common ones. It now keeps a guaranteed floor of samples **per distinct layout version**, so a brand-new version (WHOOP 4.0 v19, 5/MG v20/v21) survives until we can study it. Thanks @airtonzanon and everyone sending strap logs.

---

## 3.6.0 — A fresh look (new gold-on-navy icon) + Android sleep durability

- **New app icon, everywhere:** a bolder Titanium & Gold mark — a **thick gold recovery ring + core on deep navy** — replacing the machined-titanium tile across iPhone, Mac and Android launchers, the in-app `BrandMark`, and the README logo. Generated from `Tools/make_icon.py` (gold ramp `#FCEBA8 → #E8B84B → #C8902F` on navy `#070C16`).
- **Android durable sleep editing (parity with v3.5.0 on iPhone/Mac):** when you hand-correct a night's bed/wake times, the edit now **survives the next strap sync**. Ports @claypilat's #395 mechanism to Android: a `userEdited` flag + a recompute overlap-guard so the re-detected night can't upsert over the edit, and `startTsAdjusted` keeps `startTs` the immutable detected key (editing the bedtime no longer mutates the primary key / spawns a duplicate row). Additive Room migration v6→v7 (`userEdited`, `startTsAdjusted`), verified clean on an emulator upgrade. Fixes the latent "edited night reappears" bug. Imported WHOOP-export nights keep verbatim export recovery (same scope as iOS).

---

## 3.5.0 — Hand-correct your sleep times + smaller backups

- **Sleep bed/wake editing (iPhone/Mac, #395):** the Sleep tab gains a pencil to hand-correct a night's Asleep/Woke times. The night is **re-staged from the raw sensor data** over the corrected window (real `SleepStager` for strap nights; stage-reclip for imported ones), and the edit is **durable** — a `userEdited` flag + a recompute guard drop any re-detected session that overlaps an edited night, so a later strap sync can't revert the correction. Two additive migrations (`userEdited`, `startTsAdjusted`); `startTs` stays the immutable detected key so editing the bedtime can't spawn a duplicate row. Imported WHOOP-export nights update the displayed session but keep verbatim export recovery/performance. Thanks @claypilat.
- **Compressed `.noopbak` backups (#396):** exports are now a single-entry deflate ZIP (`noop-backup.sqlite` inside), typically 80–90% smaller — small enough to AirDrop/email. Both platforms produce and consume the same container; import sniffs ZIP-vs-raw magic bytes so older uncompressed backups still restore, and the failed-import rollback is preserved. Thanks @ujix.

---

## 3.4.0 — Tidier Today hero, strap renaming, smarter journal

- **Today hero (#394):** the three daily scores — Charge / Effort / Rest — now sit in one equal three-up row of rings, instead of the old adaptive grid that fit only two per phone width and orphaned Rest beside an empty cell. Rings shrink to fit and drop the micro wordmark so the number stays legible. Thanks @vulnix0x4.
- **WHOOP 4.0 strap renaming (iPhone/Mac, #393):** rename your strap's BLE advertising name from **Settings → Strap** while it's connected — useful for a second-hand band stuck on a previous owner's name. Uses the documented `SET_ADVERTISING_NAME_HARVARD` (cmd 77, paired with the `GET` NOOP already reads on connect); the strap reboots to apply, reversible any time, WHOOP-4-only. Thanks @rad182.
- **Android journal pre-fill (#372):** opening today's journal with no entries yet pre-fills last night's answers — **upserting real rows** so the effects engine counts the day and a tap genuinely confirms (or clears) — with a disclosing banner and bigger Yes/No tap targets. Thanks @ujix.

---

## 3.3.1 — More quick-relabel sports

- **Workouts (#318):** added **CrossFit, Hiking and Tennis** to the quick re-label presets when you change a detected workout's type (Swift + Kotlin, all platforms). Broader workout-management discoverability improvements (a more visible edit/delete affordance) are being designed as a proper follow-up — the iPhone session table scrolls horizontally, so an always-visible control needs a considered layout change rather than a button bolted to the end of the row. Thanks @marceauboul.

---

## 3.3.0 — Strap battery alerts

- **New — strap battery alerts (all platforms):** get a system notification when your WHOOP's battery runs **low (≤15%)** or finishes **charging (100%)**, so you don't get caught out before bed. A shared `BatteryAlertPolicy` fires each alert **at most once per crossing** with a re-arm hysteresis band (low re-arms only above 25% or while charging; full re-arms only after it drops below 100%), and the once-per-crossing flags are **persisted**, so a battery hovering near 15% won't nag and the gate survives an app restart. On by default; toggle under **Settings → Automations**. Reimplemented from @ujix's starting point with the jitter/restart fixes (#368).

---

## 3.2.0 — Under-the-hood: current-API migration (no behaviour change)

A maintenance release with no user-facing behaviour change.

- **iPhone/Mac:** migrated the UI off two deprecated SwiftUI/Charts calls (`onChange(of:perform:)` and `plotAreaFrame`) to their current iOS 17 / macOS 14 equivalents, behind a small `onChangeCompat` / `plotRectCompat` shim so the Mac build still compiles and runs on **macOS 13**. A single-parameter shim keeps every call-site closure byte-for-byte unchanged (zero behaviour-change risk); the deprecation is acknowledged exactly once, in the shim. Also migrated the two call sites the original change missed. Thanks @vulnix0x4 (#331).
- **Android:** versioned in lockstep; no Android-facing change.

---

## 3.1.0 — Accuracy, reliability & accessibility: a big community-fixes wave

A large wave of community-contributed fixes, each independently verified and reimplemented under the project. Credits inline.

- **Smart alarm now re-arms daily (all platforms):** a continuously-connected strap keeps waking you past the first morning instead of firing once and going silent. On WHOOP 5/MG the strap firmware alarm stays gated behind the Experimental toggle until it's confirmed. Thanks @vulnix0x4 (#376, #379).
- **More honest numbers:** workout calories count sparse (WHOOP 5/MG) heart-rate streams correctly without over-counting your whole day; heart-rate zones are no longer inflated by an off-wrist gap; daytime stress no longer false-alarms from overnight sleep; the recovery baseline reads imported data cleanly. Thanks @vulnix0x4 (#360, #366, #357, #387).
- **Bluetooth & live HR:** WHOOP 5/MG keeps decoding correctly after iOS relaunches the app in the background (#378); the Lock-Screen / Dynamic-Island live HR ends on disconnect instead of freezing a stale number (#386). Thanks @vulnix0x4.
- **Safer data:** a failed import keeps your existing data instead of risking an empty database (#383); the AI Coach never sends a key saved for one provider to a different one (#385). Thanks @vulnix0x4.
- **Accessibility & polish (iPhone/Mac):** Reduce Motion on the breathing orb (#359), VoiceOver on the 24-hour HR chart (#362), Dynamic Type scaling (#381), bigger day-navigator tap targets (#363), 12/24-hour + localized Sleep/Stress times (#361, #388), and a smoother Today screen during live HR (#358). "What's New" is no longer skipped after a combined Terms + version update (#389); the Mac menu-bar live-feed toggle is accurate (#390). Thanks @vulnix0x4.
- **Android:** tappable workout rows with a detail sheet (#370) and a fixed sleep-consistency tile (#367) — thanks @ujix; the Rest confidence dot now matches iPhone/Mac (#373).

---

## 3.0.3 — Large Apple Health imports no longer crash (iPhone/Mac)

- **Fixed (iPhone/Mac):** importing a large, multi-year Apple Health export no longer runs out of memory and closes the app — the importer aggregates day-by-day as it reads instead of holding every sample in memory (Android already worked this way). Also accepts a localised export filename (e.g. `экспорт.xml`) instead of requiring `export.xml`. Thanks @exzanimo (#355).

---

## 3.0.2 — Bluetooth stream + Apple Health sync fixes

- **Fixed:** a corrupt/misaligned Bluetooth frame could wedge the live data stream until a reconnect — NOOP now resyncs to the next real frame. Thanks @vulnix0x4 (#374). *(Android already carried this guard.)*
- **Fixed (iPhone):** the two-way Apple Health sync read its own write-backs (your strap + Apple Health could plot the same line; a failed sync could falsely report success) — it now excludes NOOP's own samples on read. Thanks @vulnix0x4 (#375).

---

## 3.0.1 — Cleaner score rings + a few fixes

- **Changed:** removed the small gold dot in the centre of the Charge / Recovery rings (behind the number) — launch feedback was that it crowded the read-out. The clean ring + number + micro-NOOP wordmark stay; the dot now lives only in the standalone logo.
- **Fixed:** Steps on Today prefer your strap's own on-device count (WHOOP 5/MG) over Apple Health, matching Android (#276).
- **Fixed:** a real overnight sleep that runs late (or has a brief morning stir) no longer truncates your wake time to late morning — your true wake time is kept. Thanks @vulnix0x4 (#353).
- **Fixed (Android):** HR-zone coaching now persists and buzzes your strap entering your top zone / on recovery — closing the gap with Mac/iPhone. Thanks @cbarrado (#350).
- **Internal:** fixed red CI on `main` (a SwiftUI type-check timeout in the stress gauge; two long-standing Liftosaur importer bugs). Added v25-PPG feasibility guard tests (#307/#194).

---

## 3.0.0 — A whole new look: "Titanium & Gold"

A complete, ground-up redesign of all three apps. Deep-navy surfaces, a warm gold hero accent, brushed-titanium detail, and a per-domain colour world — blue sleep, amber strain, teal HRV, burnt-orange stress — set in Helvetica across iPhone, Android and Mac.

- **New look (all platforms):** "Titanium & Gold" — repainted every screen: layered ring gauges, frosted per-domain cards, cleaner hierarchy.
- **New app icon:** the recovery ring engraved into machined titanium with a gold core — plus a **Settings → App Icon toggle** to switch to a darker "blued-titanium" variant.
- **New in-app brand mark** on the splash, onboarding and navigation.
- **Refined UI/UX:** a consistency pass across the board — tidier cards, cleaner date selectors (no more dark-yellow blocks), smoother transitions, and a tab bar with the centre "+" in its own space (Live heart rate moved to the "+" quick-actions menu).

---

## 2.18.5 — Today tiles no longer cut their value to "10…" (Android)

- **Fixed (Android):** on phones, Today tiles that show a sparkline (Charge, Rest, Respiratory, HRV…) were truncating their value to "10…" or "15…" — the value and the inline trend line were competing for horizontal space. The value now shrinks to fit, the way it already does on Mac/iPhone, so it always reads in full. Thanks @asemfahad (#332).

---

## 2.18.4 — Dynamic Island toggle now actually turns it off

- **Fixed (iPhone):** turning off "Live heart rate in Dynamic Island" in Settings now genuinely removes it. If the heart had started in an earlier app session, the in-app toggle couldn't reach it to switch it off — only the iOS system switch worked. The app now re-adopts an already-showing Live Activity, so the toggle ends it immediately. Thanks @gingerbeardman (#341).

---

## 2.18.3 — Workouts header layout fix (phone)

- **Fixed:** on the Workouts screen, the "Add workout" button was crushed into a tall sliver next to the range selector on phones. The button and the 7D/30D/90D selector now stack cleanly. Thanks @RichrdJ (#339).

---

## 2.18.2 — Times follow your 12-/24-hour setting

- **Fixed:** the heart-rate chart tooltip and workout time ranges showed a fixed 24-hour clock (e.g. 19:10). They now respect your device's 12-/24-hour setting — "7:10 PM" where you prefer 12-hour, "19:10" where you prefer 24-hour. Thanks @rad182 (#337).

---

## 2.18.1 — Toggle the live-HR Dynamic Island

- **New (iPhone):** a toggle to keep your live heart rate out of the Dynamic Island / Lock Screen — **Settings → Strap → "Live heart rate in Dynamic Island"**. On by default. Thanks @gingerbeardman (#336).

---

## 2.18.0 — Export your raw sensor data (CSV)

- **New (experimental):** a Settings **Export raw sensor data (CSV)** button dumps the decoded per-sample streams NOOP stores (heart rate, R-R, accelerometer, motion/step counter, SpO2/PPG, events) for the last 24h as a plain CSV — for prototyping your own sleep / activity / VBT algorithms on real data, no BLE coding. On-device only. Thanks @maddognik / @alacore (#322/#276).

---

## 2.17.1 — Charge shows "Calibrating" instead of "No data" for new straps

- **Fixed:** a brand-new strap showed a bare "No data" on Charge while it was still learning your baseline. It now reads "Calibrating — 0 of 4 nights" so it's clearly building, not broken. (Charge needs a few nights of wear; Effort and Rest show right away.) Thanks @umarXBT (#335).

---

## 2.17.0 — iPhone polish + accessibility

- **iPhone:** the floating tab bar no longer hides the last card on scrolling screens. Thanks @vulnix0x4 (#333).
- **iPhone:** tappable cards give a subtle press response + light haptic, and the manual-workout sheet has a drag-handle + decimal keypad with Done. Thanks @vulnix0x4 (#329, #330).
- **Accessibility:** charts read a one-line VoiceOver summary, and the gauge draw-in respects Reduce Motion. Thanks @vulnix0x4 (#334).

---

## 2.16.1 — Today tiles no longer truncate their value (Android)

- **Fixed (Android):** some Today tiles cut their value off to "…" (Effort, Rest, Respiratory, and the
  Last Workouts durations) — the value now shrinks to fit instead of truncating, matching Mac/iPhone. Thanks @asemfahad (#332).

---

## 2.16.0 — A round of look-and-feel polish

- **Sleep:** a clearer hypnogram — short stages read as bars not ticks, Deep is more legible, and a time axis marks onset / midpoint / wake. Thanks @vulnix0x4 (#323).
- **Live:** the Scan & Connect action is front-and-centre when disconnected, the redundant "Offline" badge is gone, idle tiles read a calm "Offline". Thanks @vulnix0x4 (#325).
- **Trends:** reading-count shown once, natural footer units ("Mean 69 ms"), "<1%" for tiny moves, peaks clear the top gridline. Thanks @vulnix0x4 (#326).
- **Effort:** gauge + accents brighten across the full amber ramp, and the Week-in-Review Effort gauge honours your 0–100 / 0–21 preference. Thanks @vulnix0x4 (#328).

---

## 2.15.3 — Android GPS route distance fix

- **Fixed (Android):** GPS workouts could record a route far shorter than reality (a real run saved as
  only tens of metres). The route filter was dropping too many legitimate fixes on weaker GPS signal — it
  now keeps the points it should, so distance and route record properly. Thanks @don86nl (#324).

---

## 2.15.2 — Today header date fix (west of UTC)

- **Fixed:** the Today header date could read one day behind the day-nav pill (e.g. "Saturday, 13 June"
  under a "14 Jun" pill) for anyone in a timezone west of UTC — it now matches. Thanks @vulnix0x4 (#320).

---

## 2.15.1 — Last Workouts tile fix

- **Fixed (Android):** the **Last Workouts** tiles on Today no longer truncate the workout
  duration to "1…" — the duration now gets the room it needs alongside the calorie chip. Thanks @nhe (#319).

---

## 2.15.0 — The new look everywhere, plus sleep, Effort & Bluetooth fixes

- **The new look, everywhere.** Every screen now wears NOOP's premium dark design — scenic
  backdrops, glowing ring gauges for Charge/Effort/Rest, and frosted per-domain cards — across
  Sleep, Recovery, Stress, Workouts, Live, Health, Trends, Insights, Breathe, Coach and Settings,
  on Mac, iPhone and Android. Same data, same on-device privacy.
- **Fixed (sleep day):** if you fall asleep before midnight and wake before ~4am in a timezone
  other than UTC, Today now shows last night's sleep instead of the night before. Thanks @maddognik (#304).
- **Fixed (sleep detection):** on WHOOP 5.0 a full night is no longer chopped into tiny fragments
  and dropped — NOOP holds the night together from your heart rate when motion data is sparse. Thanks @umarXBT (#308).
- **Fixed (Effort scale):** the Effort gauge on Today, Live and Workouts now follows your 0–100 /
  0–21 preference instead of always showing 0–21, and older imported days are re-scored onto the 0–100 axis. Thanks @maddognik (#313).
- **Fixed (Android Bluetooth):** turning Bluetooth off — or flight mode — no longer leaves NOOP
  showing a phantom "connected" or crashing on the next buzz; it cleanly shows disconnected and reconnects when Bluetooth returns. Thanks @pilleuspulcher-blip (#314).

---

## 2.14.1 — Continuous workouts no longer split, plus delete a sleep session

- **Fixed:** a long, continuous workout — like a 4-hour ride — no longer fragments into several tiny
  separate workouts. The auto-detector now stitches a sustained effort back into one session across brief
  dips and short signal drops, while a genuine rest still ends the workout. Thanks @ck090 (#303).
- **New (Android):** you can now **delete a sleep session** — tap the trash icon on the Sleep screen to
  remove a mis-detected night. Thanks @ryanbr (#281).

---

## 2.14.0 — A beautiful new look

- **New design.** NOOP has a gorgeous new look — deeper, calmer, more premium. A dark blue-black canvas,
  **layered ring gauges** for your Charge, Effort and Rest scores with glowing accents, **frosted tinted
  cards**, and a refreshed Today, across Mac, iPhone and Android. Same data and the same on-device
  privacy — it just looks the way it always should have. More screens get the full treatment over the
  coming updates.

---

## 2.13.0 — A big iPhone update, plus a WHOOP-style Today chart for everyone

- **New:** a **WHOOP-style Overview chart** on Today — the 24-hour heart-rate line now carries a sleep
  band, your Charge at wake, your Effort at now, and a sport glyph at each workout's HR peak (Mac,
  iPhone and Android). Thanks @rad182.
- **New:** the **Sleep** screen shows your **asleep and woke times** at a glance. Thanks @vulnix0x4.
- **New (iPhone):** two-way **Apple Health** you can turn on (now reaching strap-only users), a full
  **accessibility pass** (VoiceOver, Reduce Motion, 44pt touch targets), **pull-to-refresh**, the screen
  staying awake plus haptics during Breathe/Interval sessions, a **Siri & Shortcuts** screen, a readable
  iPad layout, and background strap reconnect via CoreBluetooth state restoration. Thanks @vulnix0x4.
- **Fixed:** Apple Health workout counts, secondary screens now refresh after a sync, the Compare chart
  is readable by touch, 'Mark a Moment' stamps the right time, and a long list of iPhone copy/layout
  polish. Thanks @vulnix0x4 and @khalilkm01.

---

## 2.12.0 — Continuous HRV capture (opt-in): sharper overnight HRV, recovery and sleep

- **New (opt-in):** **Continuous HRV capture.** Your strap streams dense beat-to-beat heart-rate
  variability in the clear, but apps usually only listen while a live screen is open — so overnight,
  when HRV, recovery and sleep need it most, the data goes quiet. Turn this on (**Settings → Strap**,
  with background connection enabled on Android) and NOOP keeps the stream open in the background,
  banking roughly an interval a second all night for much sharper overnight HRV, recovery and sleep —
  especially on WHOOP 5.0/MG. It uses more battery, so it's off by default and entirely your call.
  Big thanks to @Extazian, whose reverse-engineering proved this is reachable without touching
  anything encrypted (standard HR characteristic, no DTLS, nothing near your WHOOP account).

---

## 2.11.1 — Your day now follows your timezone, not UTC

- **Fixed:** on phones away from UTC (most of the world), the dashboard could appear to **freeze partway
  through the day** — new steps and readings stopped showing even though the strap was syncing perfectly.
  NOOP was filing each day by UTC midnight instead of *your* local midnight, so once your clock crossed
  the UTC boundary, fresh data landed in the next day's bucket where the screen wasn't looking. NOOP now
  buckets every day by your local day, everywhere. Thanks @Meriquium (#277).

---

## 2.11.0 — A smart wake alarm, live workout mode, an editable Today, and lifting imports

- **New (Android):** a **smart wake alarm** — set a wake window and NOOP wakes you on a lighter sleep
  phase inside it, with a guaranteed alarm at the end of the window. The guaranteed wake is a real OS
  alarm that fires even if Bluetooth drops or the app is closed. Thanks @subscriptiondestroyer (#207).
- **New:** an evening **wind-down nudge** on every platform — a gentle reminder, timed from your usual
  wake time and sleep need, that it's time to start winding down. (A sideloaded iPhone/Mac app can't
  sound a dependable wake alarm, so those get the nudge, not the wake alarm.)
- **New:** **live workout mode** — a full-screen in-exercise view with big live heart rate, your
  current HR zone, elapsed time and live effort. Thanks @subscriptiondestroyer (#238).
- **New:** **editable Key Metrics** — choose which tiles appear on Today and reorder them to taste.
  Thanks @umarXBT (#251).
- **New:** an **Effort scale toggle** — show Effort on NOOP's 0–100 axis or WHOOP's familiar 0–21
  Day-Strain axis, everywhere it appears. Display-only; your stored data is unchanged. Thanks @umarXBT (#268).
- **Improved:** the **sleep hypnogram is smoother** — brief sub-3-minute stage flecks merge into their
  neighbours so the graph reads cleanly, biased toward the lighter stage so it never inflates Deep or
  REM. Thanks @umarXBT (#274).
- **New:** **import your lifting log** from Hevy (CSV) or Liftosaur (JSON) — each workout lands as a
  Strength session with an honest training volume-load (weight × reps), kept separate from your
  heart-rate Effort. On-device, nothing uploaded. Thanks @marceauboul and @maddognik (#272/#232).

---

## 2.10.0 — Sleep-debt, daytime stress, a recovery forecast, and day-by-day navigation

- **New:** a **sleep-debt ledger** on the Sleep screen — a running 14-night balance of how much sleep
  you've banked versus your personal need, with a plain-English read and a per-night chart. (#242)
- **New:** a **daytime stress timeline** on the Stress screen, built from the day's heart rate and R-R,
  with a gentle nudge toward a Breathe session when it stays elevated. (#239)
- **New:** a **recovery forecast** on the Intelligence screen — an evening estimate of tomorrow
  morning's Charge from today's effort, your planned sleep and your recent baseline. Clearly labelled an
  estimate, with an error band, shown once there's enough history. (#240)
- **New:** **navigate Today day by day** — chevrons + a date-picker jump replace the fixed 3-day
  selector, on every platform. Thanks @ujix. (#255)
- **New (Android):** a live **strap-battery %** and **recorded-nights streak** on the Today header.
  Thanks @ujix. (#256)
- **Improved (iPhone/Mac):** the Live tab is noticeably **smoother** — the rapid strap stream no longer
  re-renders the whole screen on every frame. Thanks @nick318. (#271)
- **Fixed (iPhone):** tidied the Today Synthesis card alignment and the manual-workout field widths.
  Thanks @RichrdJ. (#234)

---

## 2.9.0 — Background GPS, sleep-time editing, log-ahead, and a sharper Rest tile

- **Fixed (Android):** GPS workouts now keep tracking with the screen off. Distance was badly
  under-counting (a 2.8 km ride logged as 0.4 km) because tracking ran on the screen — it now runs in
  the always-on background service, so your route survives the screen turning off and the phone going
  in a pocket. Thanks @pilleuspulcher-blip. (#215)
- **Fixed:** the "Rest" tile on Today now shows your Rest **score** (out of 100, like Charge and
  Effort), with hours-in-bed kept as the caption — it was showing the hours where the score should be.
  Thanks @subscriptiondestroyer. (#248)
- **New (Android):** the Sleep screen gains in-app bed/wake-time editing — fix a mis-detected night and
  every metric recomputes live — plus Hours-vs-Needed and Sleep-Consistency cards, night-by-night
  navigation, and tappable metric details. Thanks @ujix.
- **New:** log journal entries for **tomorrow**, not just today and yesterday — today's activities
  inform tomorrow's recovery. Thanks @Eph00n. (#237)
- **Fixed (iPhone):** the Explore list could appear empty even though the data was there — it now
  renders immediately with a brief "scanning" hint instead of a blank list. Thanks @sebastianwoo. (#199)
- **Improved:** body vitals now show which source each reading came from (your WHOOP, NOOP's own
  computation, or Apple Health) and merge them field-by-field. Thanks @khalilkm01.
- **New (Android):** tap-and-drag to inspect the Stress chart, and a cleaner Explore metric picker.
  Thanks @ujix.
- **New:** an optional, read-only local-access package (MCP) for power users who want to query their
  own on-device NOOP data from local tools — opt-in, nothing leaves the device. Thanks @khalilkm01.
- Also fixed a heart-rate-ingest startup crash that a community ADB log surfaced. Thanks @maddognik. (#224)

---

## 2.8.9 — Fixes the Insights-tab crash, plus more accurate HRV

- **Fixed (Android):** the Insights tab crashed for anyone with journal entries — a text-matching pattern
  used a flag that works on a computer but not on Android's regex engine, so it threw the moment you opened
  Insights. Fixed, with a regression test. Thanks @pilleuspulcher-blip and @maddognik. (#224/#267)
- **New (Android):** if NOOP ever crashes, the details are now captured into the strap log you share — so a
  crash that only reproduces on your device can actually be diagnosed. (#33)
- **More accurate HRV:** the heart-rate variability NOOP computes from a session now discards stray, irregular
  beats before averaging — the same cleaning the rest of its HRV maths already does — so a noisy WHOOP 5/MG
  optical reading no longer comes out inflated. Thanks @frazzle28. (#262/#235)
- **Fixed (Mac):** the sidebar and the Settings strap card could disagree about your connection — one saying
  "Connecting…" while the other said "Connected" for the same state. They now share one source. Thanks
  @gingerbeardman. (#266)
- **Fixed (Mac & iPhone):** the experimental WHOOP 5/MG deep-data unlock now requires the full encrypted bond.
  A live-HR-only link (strap still owned by the official app) can't carry the unlock, so the button waits for
  a real bond and tells you to free the strap from the official app first. Thanks @Joshsil03. (#269)
- **New (Android):** the "Start a workout" sport list shows a scrollbar so you can tell it scrolls, and adds
  Tennis, Squash and Table tennis. Thanks @nhe. (#265)
- **New (Android & Mac):** the Intelligence "By Day" list gets a W / M / 3M / 6M / 1Y / ALL range filter.
  Thanks @ujix. (#252)
- **New (Android):** the Today heart-rate chart is now tap-and-drag interactive, matching iPhone and Mac.
  Thanks @ujix. (#254)

---

## 2.8.8 — Better strap-log diagnostics

- **Improved:** shared strap logs now record which historical data layout your strap uses (v18/v24/v25/v26)
  and the Bluetooth signal strength at connect — invisible day-to-day, but it makes diagnosing a sync issue
  from a shared log much faster. Thanks @ryanbr. (#241)

---

## 2.8.7 — Readiness shows its evidence, and a Health Connect distance fix

- **New:** each Readiness signal now shows the numbers behind it — e.g. *HRV 72 vs 60 ms*, *Resting HR 46
  vs 52 bpm*, *Training load 7d 10.0 / 28d 10.0* — so you can see exactly why a signal is flagged, not just
  the label. Thanks @khalilkm01.
- **Fixed (Android):** a workout imported from Health Connect could show no distance even when it was
  recorded — a relay app (e.g. Suunto via Health Sync) often writes the distance with timestamps slightly
  offset from the workout, which NOOP's exact-window match missed. It now matches with a tolerance. Thanks
  @pilleuspulcher-blip. (#215)
- **Fixed (iPhone):** on the Explore screen, tapping a metric could bounce you back to the More tab instead
  of opening it — a nested-navigation bug. Drilling into a metric now works. Thanks @sebastianwoo. (#199)

---

## 2.8.6 — iPhone diagnostics & expectations, clearer labels, a journal fix

- **New (iPhone):** a *Using NOOP on iPhone* note in Settings sets honest expectations (sideloading,
  re-signing, unlocking after a reboot so history can sync) and shows how many days until your
  sideloaded build expires. Shared strap logs now carry the iPhone details (iOS version, lock state,
  background-refresh, low-power) that make iPhone-only issues quick to diagnose, with a one-tap
  Diagnostics screen to copy them.
- **Fixed:** copy that said "this Mac" now reads correctly on iPhone. Thanks @robin-liquidium. (#225)
- **Fixed:** the journal could show the same prompt (e.g. magnesium) twice after importing — duplicates
  are now merged, on every platform. Thanks @maddognik. (#224)
- **Improved (WHOOP 5/MG):** the heart rate NOOP derives from the optical sensor on sleeping (sub-60 bpm)
  stretches no longer risks snapping to ~60 bpm from a recording artifact, while a genuine 60 bpm is
  preserved. Thanks @ryanbr. (#194)

---

## 2.8.5 — Fixed: iPhone import, and a stuck store now self-heals

- **Fixed (iPhone):** importing a WHOOP or Apple Health export could silently do nothing — iOS handed the
  app an iCloud file that hadn't downloaded yet. NOOP now downloads a local copy first (through the system
  Files picker), so imports actually go through. Thanks @adrnxq and @Chopin85. (#179)
- **Fixed (iPhone):** if a NOOP backup from another platform had been restored (e.g. an Android backup onto
  an iPhone), the app could get permanently stuck on "store not ready" — the imported database held the data
  but not the bookkeeping NOOP's database engine needs, so it crashed on every open. NOOP now recovers
  automatically on the next launch, and declines such a backup at import time with a clear explanation (use
  the WHOOP-format CSV export to move history across platforms instead). Thanks @NoahMcE. (#222)

---

## 2.8.4 — New: a guide to how your Charge, Effort and Rest scores work

- **New:** a clear in-app guide to how NOOP's three daily scores — **Charge**, **Effort** and **Rest** —
  are calculated, and how they differ from WHOOP's Recovery, Strain and Sleep. Tap the ⓘ on any score on
  the Today screen, or open it any time from **Settings → About → How your scores work**. New users get a
  one-time card pointing to it.
- **New:** each score now explains how sure NOOP is of it (**Solid / Building / Calibrating**) and carries
  a one-line description of what it measures. The wiki's *The Science* and *Charge, Effort & Rest* pages
  were refreshed to match.

---

## 2.8.3 — Fixed: imported data and strap sync getting stuck on iOS

- **Fixed (iOS):** after importing your data, the strap could get stuck on "store not ready" and never
  sync — imported history wouldn't appear and backfill never started. On iOS the local database was
  sealed behind the device's data protection while the phone was locked, so a background reconnect
  couldn't open it (macOS and Android were never affected). NOOP now stores its database at the right
  protection level — readable after you first unlock since boot, still encrypted at rest — and retries
  automatically, so sync proceeds. Thanks @NoahMcE. (#222)
- **Improved:** store-open failures are now written to the strap log with the real reason instead of
  failing silently, so problems like this are diagnosable at a glance.

---

## 2.8.2 — Cross-platform parity: Android now scores identically to macOS & iOS

A maintenance release from a full three-platform parity audit of the scoring and decode paths.
No new features — these bring Android's numbers into exact agreement with macOS/iOS.

- **Fixed (Android):** Charge could read slightly low because the skin-temperature term was weighted
  twice as hard as on macOS/iOS. All three apps now compute Charge identically. (#219)
- **Fixed (Android, WHOOP 5/MG):** the HR NOOP derives from the optical (PPG) sensor on stretches with
  no measured HR now uses the same harmonic-rejecting estimator as macOS/iOS (it could previously lock
  onto half or double the true rate) and recovers HR from short data runs the way the other apps do. (#219)
- **Fixed (Android):** the respiratory-rate early-illness signal in Readiness now uses the same
  sensitivity thresholds and plausible-range filter as macOS/iOS.
- **Fixed:** smaller cross-platform tidy-ups — skin-temperature data kept over the same range on every
  platform (Android was dropping valid just-put-on readings), CSV exports round-trip byte-for-byte, and
  a couple of score-rounding edge cases now agree across apps.

---

## 2.8.1 — Battery + responsiveness: smarter sync, lighter notification

- **Improved (battery):** NOOP backs off history-sync polling when the strap keeps handing over nothing
  (off-wrist / not banking) instead of re-trying every 90s; a manual or reconnect sync still runs
  instantly. Thanks @ryanbr. (#217)
- **Improved:** a just-synced night's Charge / Effort / Rest appear the moment the sync finishes, not up
  to 15 minutes later. Thanks @FrostDev7. (#218)
- **Improved (Android, battery):** the persistent notification no longer re-draws with live HR every
  second — it updates only when connection / sync / recovery / battery changes. Thanks @Eph00n & @spasypaddy. (#216)

## 2.8.0 — New: Week in review, a live body console, fresher charts & more

A wave of new features and community contributions, reimplemented under the project identity.

- **New — Week in review (#208):** a deterministic, offline weekly digest (Charge / Effort / Rest,
  HRV, resting HR) with week-over-week + vs-baseline changes and a plain-English read, at the top of
  **Trends**. Thanks @subscriptiondestroyer.
- **New — live body console (Live screen):** a clearer readout of HR, recent R-R, rolling RMSSD and the
  live connection/signal state. Thanks @khalilkm01.
- **New — live HR time axis (#198):** the live heart-rate chart now shows the time window. Thanks @sebastianwoo.
- **Improved — freshest-source resolver:** charts/metrics resolve the freshest value per metric
  (imported WHOOP → NOOP-computed → compatible Apple Health). Thanks @khalilkm01.
- **New — personal experiments (Insights):** an n-of-1 section correlating a logged behaviour against
  recovery, gated to behaviours you have data for. Thanks @khalilkm01.
- **Improved — AI Coach:** surfaces context-window truncation and caps history sent to local servers.
  Thanks @witchykinkajou.
- **Improved (Android):** Today + Trends charts gain time/value axis labels. Thanks @ujix.

## 2.7.0 — Big fix wave: clock, reconnect, local LLM, Explore, weight and more

A large batch of fixes from reported issues and community contributions.

- **Fixed (WHOOP 4.0):** straps on firmware 41.17.x silently failed to set their clock → no history,
  no sleep/recovery. NOOP now sends both clock-command formats. Thanks @rad182. (#120)
- **Fixed:** strap sometimes wouldn't reconnect after an app update — NOOP rotates the scan between
  WHOOP 4 and 5/MG. Thanks @khalilkm01.
- **Fixed (AI Coach):** the Custom provider can now reach a local LLM on your LAN (e.g. Ollama at
  `http://192.168.x.x:11434`), not just `localhost`, on Android and iPhone — cloud providers stay
  HTTPS-only. Thanks @andreasc1. (#187)
- **Fixed (iPhone):** the Backup buttons no longer truncate to `Ex…/Im…/E…`. (#188)
- **Fixed:** the Explore page was empty for WHOOP 5 live-Bluetooth users with no import — it now reads
  computed daily scores. Thanks @sebastianwoo. (#199)
- **Fixed:** the Today **Weight** tile uses your Settings weight when Apple Health has none. Thanks
  @subscriptiondestroyer. (#204)
- **Fixed (Android):** imported Health Connect workouts now carry distance. Thanks @pilleuspulcher. (#215)
- **Fixed (WHOOP 5/MG):** PPG-derived HR now feeds the daily scores, so a PPG-only night is scorable.
  Thanks @khalilkm01. (#212)
- **Fixed (WHOOP 4.0):** an empty history sync now reliably surfaces the charge-to-100% guidance instead
  of silently showing nothing. Thanks @alberba. (#214)
- **Fixed (Mac):** the on-device store stays in the app's sandbox container, with a one-time migration.
  Thanks @khalilkm01.
- **Fixed (WHOOP 5/MG):** the experimental deep-data telemetry no longer miscounts a trailing history
  frame as a live deep packet.

## 2.6.10 — WHOOP 5/MG deep data: live confirmation it's working

- **New (iPhone & Android, experimental):** the WHOOP 5/MG **deep-data (R22)** section now shows **live
  confirmation** of what the strap is doing — "**strap accepted 15/15 R22 flags**" the moment you send
  the enable sequence, plus a **count of deep packets** if the strap starts streaming them. You can see
  whether it's working without reading a log. A real 5/MG accepting the full sequence is now
  hardware-confirmed (#174); the remaining step is seeing the deep packets actually flow, and this makes
  it obvious the instant it happens.

## 2.6.9 — iPhone polish: What's New fits, Today cards align

- **Fixed (iPhone):** the **What's New** screen shown after an update was sized for a desktop window
  (560pt wide), so it ran off the edges of the phone — you couldn't read the notes or reach **Got it**.
  It now fits the screen. Thanks @sebastianwoo. (#185)
- **Fixed (iPhone):** in **Today's Synthesis**, the Charge read-out card is now the same height as the
  ring card beside it, so the two line up instead of leaving a gap. Thanks @sebastianwoo. (#186)

## 2.6.8 — iPhone import: handle iCloud and large export files

- **Fixed (iPhone):** importing a WHOOP or Apple Health export could still fail right after you picked
  the file (the v2.6.3 fix only un-greyed the `.zip` in the picker). NOOP now copies the picked file
  out of iCloud Drive / Files into local storage first — coordinating the read so a **not-yet-downloaded
  iCloud file** or a **very large export** actually opens — and then streams the import. macOS is
  unchanged. Thanks @adrnxq and @Chopin85. (#179)

## 2.6.7 — More-tab icons stop flickering colour

- **Fixed (iPhone):** the icons on the **More** tab briefly flashed from green to blue a second after
  the screen opened (the list was re-tinting them with iOS's default blue). They now stay the app's
  accent green. Thanks @sebastianwoo. (#184)

## 2.6.6 — iPhone Workouts table fits the screen

- **Fixed (iPhone):** the **Workouts → All Sessions** table ran off the side of the screen, clipping
  the Sport, distance and source columns. It now scrolls sideways so every column is reachable, with a
  hint that you **press and hold** a workout to re-label, edit or delete it. (macOS is wide enough to
  show the full table, so it's unchanged.) Thanks @sebastianwoo. (#183)

## 2.6.5 — Broadcast your heart rate to Garmin, Zwift and gym kit

- **New (iPhone & Android, experimental):** **Broadcast heart rate** — your WHOOP 5.0/MG can now
  advertise its heart rate as a standard Bluetooth HR sensor (`0x180D`), so a Garmin (Edge/watch),
  Zwift, Peloton or a gym machine can read it directly during a workout. Turn it on under
  **Settings → Experimental**; it's opt-in and reversible (it writes the strap's
  `whoop_live_hr_in_adv_ind_pkt` flag), and re-applied on each connection. WHOOP 5.0/MG only — a Mac
  can't write to a 5/MG. Thanks @mornepousse. (#181)

## 2.6.4 — Tidier workout names, correct Rest duration

- **Fixed:** workout names from your strap now read as proper words — **Traditional Strength Training**
  instead of `TraditionalStrengthTraining` — on the Today tiles, the Workouts breakdown cards and the
  session list, on all platforms. Thanks @RichrdJ. (#175)
- **Fixed:** the Intelligence tab's **Rest** duration could read an hour too high (a 5h 39m night showed
  as 6h 39m) because the hours component was rounded up instead of truncated. It now matches the Sleep
  tab and dashboard exactly. Thanks @FrostDev7. (#180)

## 2.6.3 — Universal Mac build + iPhone import fix

- **Fixed (Mac):** the download was accidentally an Apple-Silicon-only build, so it couldn't launch on
  Intel Macs at all (`Bad CPU type in executable`). It now ships as a true **universal binary** (x86_64 +
  arm64) that runs natively on both Intel and Apple Silicon. Thanks @stnnnts. (#177, #165)
- **Fixed (iPhone):** importing a WHOOP export or Apple Health `.zip` on a sideloaded build — the file
  picker was greying out the `.zip` (the `UTType.folder` option, a Mac-only "pick an unzipped folder"
  affordance, blocked file selection in the iOS Files picker). iOS now offers only the file types it can
  actually open, so the `.zip` is selectable again. Thanks @adrnxq. (#179)
- **New (iPhone):** an **AltStore / SideStore source** for one-tap updates on sideloaded installs — add
  `https://raw.githubusercontent.com/NoopApp/noop/main/altstore-source.json` as a source. Reimplemented
  from @RazvanRex. (#178)

## 2.6.2 — iPhone button-label polish

- **Fixed (iPhone):** action buttons that wrapped mid-word on a narrow screen — the **Live** screen's
  Re-scan / Buzz strap / Disconnect row and the **Backup** Export / Import / Export CSV row now keep each
  label on one line (shrinking to fit instead of breaking to one character per line). Thanks @marceauboul. (#175)

## 2.6.1 — Effort scale fix for imported data

- **Fixed:** imported WHOOP **Day Strain** and **workout strain** now correctly land on NOOP's 0–100
  **Effort** axis (the 0–21 → 0–100 rescale was defined in v2.6.0 but never wired up), so imported and
  on-device Effort finally share one scale. NOOP's own CSV export now writes Effort on WHOOP's 0–21 scale,
  so re-importing your own export round-trips losslessly.

## 2.6.0 — Charge, Effort & Rest: NOOP's own scores, out of 100

- **New (Mac, iOS and Android):** NOOP now has its **own daily scores, all out of 100** — **Charge** (how
  recovered and ready you are), **Effort** (the day's cardiovascular + movement load), and **Rest** (last
  night's sleep quality). Computed on-device across WHOOP 4.0 and 5.0/MG from published sports-science
  methods, no WHOOP cloud. **Charge** folds HRV, resting heart rate, respiration, your **skin-temperature
  deviation** and **Rest** into one readiness number; **Effort** is your cardiovascular load curve (rescaled
  from the old 0–21 to 0–100); **Rest** weighs duration-vs-need, efficiency, restorative (deep + REM) share
  and consistency. Renamed from Recovery / Strain / Sleep and put on one consistent 0–100 axis; imported
  WHOOP history is rescaled to match. Honest approximations, **not** WHOOP's scores.

## 2.5.0 — Experimental: unlocking WHOOP 5.0/MG deep data

- **New (Mac, iOS and Android — experimental, opt-in):** a **WHOOP 5.0/MG "deep data" unlock** under
  **Settings → Experimental**. 5/MG straps give a fresh third-party app only live heart rate; the official
  app switches on the deeper streams (high-rate HR + motion + history) by writing a set of **feature
  flags**. NOOP can now send that exact, [documented](docs/WHOOP5_DEEP_DATA.md) sequence to your strap —
  one button, only when the strap is **worn and bonded**. It does write to the strap, but it's
  **reversible** (it only changes which data the strap emits) and is the same thing the official app does.
  Experimental: it may do nothing on your firmware yet. If you own a 5/MG, turning it on and sharing your
  strap log on [#174](https://noop.fans/NoopApp/noop/issues/174) is exactly what we need to finish 5.0/MG
  support. **iPhone/Android only** — a Mac can't write to a 5/MG. Built on the public protocol work of
  **judes.club**, **Asherlc/dofek** and **b-nnett/goose**.

---

## 2.4.0 — A small, honest ask

- **New (Mac, iOS and Android):** a small card on the Today screen — at most **once every 12 hours** —
  asking whether NOOP is proving useful, with the honest numbers: a WHOOP membership runs **$300–480 a
  year**, NOOP is free and built by one person, and **5,000+ downloads in, 7 people have donated**.
  **"Later"** snoozes it 12 hours; **"Don't ask again"** turns it off permanently. It's a card in the
  flow, never a pop-over — and the stats are **baked in at release time** (`Tools/update-donation-stats.sh`),
  so the app still never touches the network.

---

## 2.3.2 — Split sleep: every block counted, one night per day

- **Fixed (Mac and iOS):** on a **Bluetooth-only** setup (no import), a day recorded as multiple sleep
  blocks showed only one — the rest were silently hidden. All blocks are now read from **both** sources,
  and a split day reads as **one night**: totals summed, the real gap between blocks preserved in the
  hypnogram, the "N nights ago" label counting days (not blocks), and a cross-midnight night showing its
  span ("Fri 13 → Sat 14 Jun"). Implemented from [PR #173](https://noop.fans/NoopApp/noop/pull/173) —
  thanks **@FrostDev7**. (Android's day totals were already correct; its per-day grouping follows.)

---

## 2.3.1 — Skin temperature unblocked on Mac/iOS, plus export fixes

All from working through @tigercraft4's PR #97 code review (which deserved a much faster response
than it got) and @sudden-break's logs on #156:

- **Fixed (Mac and iOS):** strap **skin temperature was read on the wrong scale** (raw/128 instead of the
  firmware's centidegrees), which made every real night look impossibly cold and silently discarded it —
  so the nightly skin-temp deviation never appeared from strap data. Real nights now read correctly
  (matching Android), and your deviation builds after a few nights of wear. (#166)
- **Fixed (Mac and iOS):** the strap log no longer prints a stale **"layout v25/v26 … doesn't decode yet"**
  warning for layouts NOOP decodes. (#156)
- **Fixed (all platforms):** CSV export wrote the **disturbance count into "Awake duration (min)"** — the
  cell is now empty rather than a wrong unit; **duplicate workouts** (imported + detected) are exported
  once; free-text fields are guarded against **spreadsheet formula injection**; and a failed export on
  macOS can no longer **destroy the previous export file** (atomic swap).

---

## 2.3.0 — HR from the optical waveform, an early-morning day rollover, and clearer terms

- **New (Mac, iOS and Android):** on **WHOOP 5.0/MG**, NOOP now derives a **per-second heart rate from the
  strap's optical (PPG) waveform** to fill gaps where a stored HR isn't available. It's **heart-rate
  continuity only — it does not reconstruct HRV** — and a measured HR always takes priority over a derived
  one. (#156, thanks @j0b-dev)
- **Fixed (Mac, iOS and Android):** your day now **rolls over in the early morning (~4am)** instead of at
  midnight, so a late-night workout or a 1am glance still counts toward the right day rather than resetting
  underneath you. (#144)
- **Improved (Mac, iOS and Android):** nights with **more than one sleep block** (naps, split sleep) are now
  grouped by day, so each block is shown and navigated correctly. (#160)
- **New (Android):** an **"All other apps"** toggle under **Notifications → Behaviour** buzzes your wrist for
  any app that isn't in the curated list (e.g. BeReal). Opt-in and off by default; quiet hours and
  only-when-worn still apply. (#168)
- **Fixed (Mac):** the Today **heart-rate trend chart** no longer bleeds its gradient down the page behind the
  cards beneath it.
- **Updated terms (v1.1):** added plain-English, explicitly **non-clinical** notes for the **Mind** mood
  check-in, **nutrition import**, and the iOS **"Export for Shortcuts"** path. You'll be asked to
  re-acknowledge once on first launch.

---

## 2.2.1 — Shortcuts-export duplicates fixed; nutrition & mood reach Android charts

- **Fixed (iOS):** the **"Export for Shortcuts"** file is now **truncated when there's nothing new**, so
  a Shortcut automation firing on every app close can't re-import the previous rows into Apple Health —
  exports are strictly differential. (#167, thanks @alexsas00)
- **Fixed (Android):** imported **nutrition** (calories-in, protein, carbs, fat) and your **Mood** series
  now appear in **Explore and Compare** with proper names and units — they were stored but invisible to
  the metric pickers.

---

## 2.2.0 — Mind: a daily mood check-in, and nutrition import

- **New (Mac, iOS and Android):** **Mind** — a one-tap daily **mood check-in** (five faces) on the
  Insights screen. Over time it shows, **privately and on-device**, how your mood tracks with your HRV,
  sleep and recovery (e.g. *"on days your HRV is higher, your mood averages higher"*). It's
  self-tracking, **not a clinical assessment**, and nothing leaves your device.
- **New (Mac, iOS and Android):** import a **nutrition CSV** (Cronometer, MacroFactor, or a generic
  export) — your daily **calories-in, protein, carbs and fat** land alongside your strain and recovery
  in Explore and Compare, so you can finally see calories-in next to calories-out. Offline, file-based,
  optional.

---

## 2.1.0 — Browse past nights, a smarter Coach, workout times, battery & more

- **New (Mac, iOS and Android):** the **Sleep** screen now lets you **browse past nights** — tap ◀/▶ on
  the hypnogram to step back through every recorded night, not just last night. (#160, thanks @FrostDev7)
- **Fixed (Android):** the **AI Coach** now sees the recovery, strain, sleep and HRV that NOOP computes
  **on-device** for live-strap users — it had only been reading imported rows, so a Bluetooth-only user's
  Coach wrongly claimed it had no data. (#124)
- **Fixed (Android):** your imported **step count now updates for *today***, not just past days — NOOP
  refreshes today's Health Connect steps when you open the app. (#150)
- **New (Mac, iOS and Android):** workouts now show their **start–end time** (e.g. 13:00–13:30), and the
  Today screen shows your **strap's battery level**. (#157, #159)
- **New (Mac, iOS and Android):** a **Step calibration** setting — if your step count runs high on a
  WHOOP 5.0/MG, set how many motion-counter ticks equal one real step (the default leaves counts
  unchanged). (#139)
- **New (Mac, iOS and Android):** **Breathe** sessions now show your **HRV response** — how much your
  RMSSD rose from start to finish, and the peak — so you can see the calming effect land.
- **New (iOS):** an opt-in **"Export for Shortcuts"** that writes your heart rate, HRV and steps to a file
  an Apple Shortcut can log into Apple Health — a HealthKit-free path for sideloaded installs. (#155,
  thanks @alexsas00)
- **Hardened (Mac, iOS and Android):** the archived-sleep retro-decode now **retries on the next launch**
  if a save fails midway, instead of giving up — recovered history is never lost to a transient error.
  (#152, thanks @ryanbr)

---

## 2.0 — Clearer answers when your strap isn't banking history

- **Improved (Mac, iOS and Android):** your strap log now records what a sync **saved**, not only what
  failed — a `persisted N rows (M with motion) across K night(s)` line on every successful offload.
  NOOP previously logged only failures, so a shared log couldn't actually show whether history was
  banking; now it can. (#150)
- **Improved (Mac, iOS and Android):** when the strap reports it has no stored history to hand over (its
  "no flash cursor" state, `trim=0xFFFFFFFF`), NOOP now names the real cause plainly — the strap's clock
  has lost sync and it isn't saving to flash, a **charge/clock state on the strap, not a NOOP decode
  bug**. The Troubleshooting and FAQ guides now lead with this — the most common reason recovery and
  sleep don't appear — with the fix: fully charge to 100% and reconnect. (#150)

---

## 1.99 — Your imported steps now show on the Today screen (Android)

- **New (Android):** the Today screen's **Steps** tile now shows the steps from your Apple Health /
  Health Connect import when the strap didn't bank an on-device count — so a **WHOOP 4.0**, which NOOP
  can't yet read steps off over Bluetooth, shows your imported steps instead of "No Data" (Mac and iOS
  already did this). Worth saying plainly: the WHOOP 4.0 **does** count steps in the official WHOOP app
  — the only gap was that NOOP couldn't surface them yet. (#150)

---

## 1.98 — The archived-sleep recovery now reaches Android too

- **Recovered (Android):** the reject-archive retro-decode that landed on Mac & iOS in v1.97 now runs
  on **Android** as well. If your WHOOP 4.0 on Android synced "v25" firmware records before v1.95 — when
  NOOP couldn't read that layout — that sleep and recovery were saved but left dark; on update NOOP
  re-runs them through the current decoder and backfills those nights. (#151)

---

## 1.97 — Sleep that was stuck in the archive comes back

- **Recovered (Mac, iOS & Android):** if your WHOOP 4.0 synced "v25" firmware records *before* v1.95 —
  when NOOP couldn't decode that layout yet — those records were saved to NOOP's on-device archive but
  left dark, and the strap had already freed them. NOOP now **re-runs that archive through the current
  decoder on update**, so your sleep and recovery from those nights backfill. Once per decoder upgrade,
  automatically. (#151)
- **Fixed (Mac, iOS & Android):** the AI Coach now formats its replies — **bold**, bullet/numbered
  lists and headings render properly instead of showing as raw Markdown symbols. (#149)

---

## 1.96 — iOS is now a direct download

- **New: iOS is a direct download.** You no longer need a Mac and Xcode — the iOS app ships as an
  **unsigned `.ipa`** you install with **AltStore** or **SideStore**, which signs it on your own
  iPhone with your own **free Apple ID**. No App Store, no Apple Developer account, no identity
  attached to the project — NOOP stays anonymous, and you self-sign on-device. See
  [`docs/IOS.md`](docs/IOS.md) for the 5-minute setup. Two honest notes: a free Apple ID re-signs
  the app **every 7 days** (AltStore automates this), and some Apple-only integrations (Apple Health,
  Live Activity widgets) can be limited under a free signing identity.
- **Fixed (Mac, iOS and Android):** the "your strap's clock has lost sync" warning no longer appears
  after a single quiet sync — it now waits for several empty syncs in a row, so a healthy strap with
  one nothing-to-hand-over cycle doesn't trigger a false alarm. (#126)
- **Fixed (Android):** Health Connect import now respects **partial permissions** — switch off the
  data types you don't want NOOP to read, and it imports the rest instead of refusing entirely. (#150)

---

## 1.95 — Sleep and recovery for WHOOP 4.0 straps on the firmware we couldn't read

- **New (Mac and Android):** some WHOOP 4.0 straps run a firmware whose offloaded history NOOP
  couldn't decode for motion — so sleep and recovery never built from the strap, even though live
  heart rate worked. NOOP now reads that firmware's motion (the accelerometer gravity vector) and
  per-second timestamps, which is exactly what the sleep engine needs. Once your strap banks a night,
  sleep staging and recovery can finally build from it. Heart rate in this layout is derived from the
  optical sensor rather than stored second-by-second, so this unlock is specifically the motion data.
  This was reverse-engineered from real on-wrist captures shared by users on #30 — thank you. (#30)

---

## 1.94 — Manual workouts on WHOOP 5.0/MG get their calories and strain back

- **Fixed (Mac and Android):** a workout you start yourself now fills in its calories, average heart
  rate and strain even on a WHOOP 5.0/MG. The live heart-rate stream on 5/MG is sparse, so a manual
  session was often saved showing ~1 kcal and no strain — now, once your strap offloads the heart rate
  it banked during the session, NOOP re-scores that workout from the fuller data (conservatively:
  well-scored workouts are left untouched, and a still-sparse window is a no-op). (#137)
- **Developer (iOS):** the experimental iOS app target is now folded into `main` and builds against
  current code (app shell, WidgetKit + Live Activity, two-way HealthKit, App Intents), with a CI job
  compiling both the macOS and iOS targets on every change. iOS remains **build-from-source only** —
  there is no App Store / TestFlight build, because that would require a non-anonymous Apple Developer
  identity. Build it yourself in Xcode if you want to run it (see `docs/IOS.md`). (#42)

---

## 1.93 — Tidy your journal — remove and hide questions

- **New (Mac and Android):** the Journal now has an **Edit mode** (tap **Edit** on the Journal card) to
  curate your questions. Delete custom questions you've added, and hide any built-in ones you don't
  use — hidden questions are listed under the card and can be restored anytime. (#140)

---

## 1.92 — Better diagnostics for newer strap firmware — so we can decode it

- **Improved (Mac and Android):** when your strap's historical records use a firmware layout NOOP
  can't decode yet — newer WHOOP 5.0/MG units, and some WHOOP 4.0 straps, which is why sleep, recovery
  and steps can be missing (see #30, #136) — the strap log now includes the **full record bytes** (it
  previously cut them off after 64) plus a few more sample records. That's exactly what we need to map
  the new layout, so a single fresh strap log from an affected device now carries everything required
  for us to add support.

---

## 1.91 — Run the AI Coach on your own model — including fully local

- **New (Mac and Android):** the AI Coach can now talk to any OpenAI-compatible server — including a
  model running locally on your own machine (Ollama, LM Studio, llama.cpp). Pick "Custom
  (OpenAI-compatible)", point it at your server URL (e.g. `http://localhost:11434/v1`) and choose a
  model; an API key is optional. With a local model, your coaching conversation and metrics never
  leave your device. (#131)

---

## 1.90 — NOOP now tells you when your strap isn't saving history — and how to fix it

- **Improved (Mac and Android):** when a sync **completes** but your strap handed over only its
  diagnostic output and **no stored history** — which means its clock has lost sync and it isn't saving
  data to flash — NOOP now says so, with the fix (**fully charge the strap to 100%, then reconnect**),
  instead of silently reporting "synced." This is the single most common reason recovery, sleep and
  strain stop appearing on a WHOOP 4.0, and it now distinguishes that from a normal caught-up sync.
  (#77, #91, #120)

---

## 1.89 — Live heart rate lands on today's chart even when the strap's clock is off (Android)

- **Fixed (Android):** if your WHOOP's internal clock was invalid (the same condition that can stop it
  banking history), live heart rate still streamed and was saved — but it got stamped with the strap's
  bogus clock, so it landed off-today and the **Today 24-hour HR trend read empty** even though live HR
  was working. Live readings are now anchored to your phone's clock as they arrive, so they always land
  on today's timeline. (#126)

---

## 1.88 — Smoother Explore charts, and a clearer way to connect a WHOOP 5.0/MG

- **Fixed (Mac):** the Explore chart no longer flickers or re-animates its line when you move the
  cursor across a card. The v1.77 fix removed one cause; a second remained — the card surface was
  animating its hover transition over its whole contents (the chart included) — now scoped to just the
  card's border and shadow. (#104)
- **Improved (Mac and Android):** connecting a WHOOP 5.0/MG is clearer. macOS first-run setup now asks
  you to **pick your strap model first** instead of defaulting to a WHOOP 4.0 scan, and selecting
  WHOOP 5.0/MG (both platforms) shows an inline note that it pairs with one app at a time — so if a
  scan finds nothing, free it in the official WHOOP app and try again. (#130)

---

## 1.87 — Deep sleep that happens later in the night no longer reads 0 minutes

- **Fixed (Mac and Android):** follow-on to the deep-sleep fix. NOOP assumes deep sleep is
  front-loaded (it usually is) and re-imposes that — but it was zeroing out **all** deep detected
  after the first third of the night, so nights where the deepest stretch lands later showed 0 m of
  deep despite a clear signature. It now only applies that rule when there's deep early in the night
  to anchor it. (#127)

---

## 1.86 — Deep sleep no longer reads 0 minutes, and a smarter AI Coach

- **Fixed (Mac and Android):** on-device sleep nights no longer show **0 minutes of deep sleep**. Deep
  required a per-epoch HRV reading, which is often sparse on Bluetooth-synced nights (especially WHOOP
  5/MG), so it was blocked entirely. It now falls back to the other depth signals (stillness, low HR,
  regular breathing) when HRV isn't measurable that second, while still requiring genuinely high HRV
  when it is. (#127, #129)
- **Improved (Mac and Android):** the AI Coach now also sees your SpO₂, respiration, skin-temperature
  deviation, steps and active energy — it previously summarized only recovery/strain/sleep/HRV/RHR. (#124)

---

## 1.85 — Browse the last few days, interactive charts, and a Vital Signs screen (Android)

- **New (Android):** browse the last **3 days** on Today, Sleep and Vital Signs — flip between Today,
  Yesterday and 2 days ago from the same screen.
- **New (Android):** charts are now **interactive** on Sleep, Trends and the new Vital Signs detail —
  tap and swipe across the line to read off the exact value at any point.
- **New (Android):** **Vital Signs** is now a first-class screen reachable from the menu — resting HR,
  HRV, SpO₂, skin temperature and respiratory rate with their recent history and context in one place.
- **Improved (Android):** more robust background reconnect — the long-lived connection and its
  persistent notification come back cleanly after an app update or restart. _(A community
  contribution — thank you.)_ (Mac: version bump only.)

---

## 1.84 — Fix the Android freeze after a few nights of data

- **Fixed (Android):** the app could freeze and get ANR-killed ("app isn't responding") once a strap
  had banked a few nights of history. The nightly sleep analysis ran a slow scan **on the main
  thread**; it now runs off the main thread, and the scan itself went from **O(n²) to O(n)** — so the
  app stays responsive regardless of how much history accumulates. (Mac was never affected — it
  already ran this off-screen.) (#125, thanks to a detailed field report)
- **Improved (Mac and Android):** the strap log no longer reads a history chunk that's only the
  strap's own diagnostic chatter as "dropped" data, and it now logs undecodable records on
  partially-decoded chunks too. (#120, #123)

---

## 1.83 — Workout calories (manual sessions + Health Connect imports)

- **Fixed (Mac and Android):** a workout you **start yourself** now estimates its calories from your
  heart rate — the same model NOOP uses for auto-detected workouts — instead of leaving the field
  blank. (#117)
- **Fixed (Android):** workouts imported from **Health Connect** (e.g. Garmin) now show their
  calories. NOOP credits each session with the active calories burned inside its time window (a
  Health Connect exercise record carries no energy of its own, so this stitches them together). (#117)

---

## 1.82 — Stop losing strap history we can't yet decode + a board of fixes

- **Fixed (Mac and Android):** NOOP no longer **destroys strap history it can't yet decode**. If a
  history chunk arrived with a bad checksum or a firmware record layout we haven't mapped, NOOP used
  to acknowledge it anyway — and the strap then **freed (erased)** that data while the screen said
  "synced". NOOP now archives those raw records **on-device before acknowledging**, and if it can't
  save them it leaves them on the strap to retry. An unrecognised firmware can no longer cost you
  your data. (#77, #91)
- **Fixed (Android):** a **Health Connect sync no longer blanks a strap-only day**. With no WHOOP
  import, a sync could write a sparse record that hid your on-device recovery/strain and regressed
  your sleep stages; Health Connect now only fills days your strap didn't already cover. Nothing was
  deleted — this restores it. (#112)
- **Fixed (Android):** the Today screen's **Steps, Calories and Weight** tiles now show real data
  instead of always "no data"; Weight falls back to your profile figure when there's no measured
  reading. (#107)
- **New (Mac):** **Google Gemini** as a third bring-your-own-key AI Coach provider (with OpenAI and
  Anthropic).
- **New (Mac):** a clear **"Standard HR mode"** note when the radio falls back to low-bandwidth heart
  rate (#80); a guard that **refuses an Android backup on Mac** instead of overwriting your database;
  and imported **Apple Health body-weight** now shows up.

---

## 1.81 — Start a workout from the Workouts screen + an honest Smart-alarm note

- **New (Android):** start a workout straight from the **Workouts** screen, not only from Live — the
  same searchable sport picker and GPS toggle, with a compact running banner and an **End** button
  while a session is in progress.
- **Changed (Android):** the **Smart alarm** now says plainly that it's experimental, and that a
  WHOOP 5/MG only arms it when **Experimental mode** is on — so your wake time is no longer silently
  saved against a strap that was never armed. Keep a backup alarm until you've confirmed it wakes you.

---

## 1.80 — Journal logging + an Imperial/Metric units toggle

- **New (Mac and Android):** a journal card on Insights — quick yes/no chips for behaviours (caffeine,
  alcohol, a late meal, screen time, and your own custom questions) so you can see what moves your
  recovery. Entries stay on-device and are never overwritten by an import.
- **New (Mac and Android):** an Imperial / Metric units toggle in Settings — distance, weight, height
  and temperature, with a separate temperature override. Display-only; stored data is unchanged.

---

## 1.79 — Manual workouts, edit/dismiss auto-detected ones, and CSV export

- **New (Mac and Android):** add a workout by hand, and edit, re-label, or **dismiss** the ones NOOP
  auto-detects — so a misread or duplicate bout no longer sticks around with no way to remove it.
  Dismissals are remembered, so a re-detected session stays hidden.
- **New (Mac and Android):** export all your data as a WHOOP-format CSV bundle (cycles, sleeps,
  workouts, journal) from Settings — yours to keep, and it imports straight back into NOOP.

---

## 1.78 — Fewer false daytime sleeps + an Android sync button

- **Fixed (Mac and Android):** a long sedentary daytime stretch no longer gets logged as sleep —
  daytime periods now need a longer, genuinely low-heart-rate window, while nights and real naps stay
  unchanged.
- **New (Android):** a manual "Sync now" button on the Live screen + an honest progress indicator
  while strap history offloads.
- **Repo:** contributor guidelines, issue/PR templates, a security policy, and build-check CI added.

---

## 1.77 — First-run terms acknowledgment + an Explore chart fix

- **New (Mac and Android):** a one-time, plain-English terms acknowledgment on first launch — what
  NOOP is, that it's independent of WHOOP and that using it may breach WHOOP's Terms of Service, that
  it's not a medical device, and that you use it at your own risk. You accept once; full terms in
  `TERMS.md`.
- **Fixed (Mac):** the Explore metric charts no longer flicker to a straight line when the cursor
  crosses into or out of the graph.

---

## 1.76 — Robust Apple Health import, marginal-radio HR mode, live HR graph

- **Improved (Mac and Android):** a very large Apple Health export no longer fails to import because
  of a single malformed byte — NOOP skips the bad spans and imports everything else, reporting how
  many it skipped. Multi-year exports that errored out before should come in fine now.
- **New (Mac):** if your Bluetooth radio can't sustain WHOOP 4's full realtime stream (older Macs /
  OpenCore), NOOP now falls back to a low-bandwidth standard heart-rate mode, so live HR keeps working
  instead of looping on a dropped connection.
- **Fixed (Mac):** the Health tab's live heart-rate graph now builds a continuous trace over time
  instead of getting stuck on two points.

---

## 1.75 — Personal vital baselines + Mac analytics parity

- **New (Mac and Android):** the Health Monitor now judges each vital — HRV, resting heart rate,
  respiratory rate, skin temperature — against **your own learned baseline** (after ~14 nights),
  not just a one-size-fits-all population range. A personal normal that sits outside the textbook
  band (e.g. a naturally lower HRV) stops reading as "off" when it's fine for you. Falls back to the
  typical range until your baseline is established.
- **New (Mac):** macOS now computes steps, respiratory rate, daily calories and nightly skin
  temperature on-device, matching Android — and nightly respiration now feeds the recovery score on
  both platforms (existing recoveries unchanged when respiration isn't available).

---

## 1.74 — Android reconnect guide + a startup-crash fix

- **Android reconnect guide (parity with Mac 1.73):** if your WHOOP 5.0 / MG can't connect after a
  firmware update (a Bluetooth pairing reset), NOOP now detects it and shows the forget-and-re-pair
  steps right in the app, instead of silently retrying.
- **Fixed (Android):** a rare startup crash on some fast devices (e.g. Galaxy S24+) — the app could
  crash once on launch when a strap was already connected, then open fine on the second try. Mac was
  never affected.

---

## 1.73 — Reconnect help for WHOOP 5.0 / MG after a firmware update

- **If your WHOOP 5.0 / MG stopped connecting after a WHOOP firmware update**, that's a Bluetooth
  pairing reset — not a lockout, and NOOP works fine on the new firmware. To reconnect: quit the
  official WHOOP app, forget the strap in your Bluetooth settings, put it in pairing mode (tap the
  band until the LEDs flash blue), then reconnect. On Mac, NOOP now detects this automatically and
  shows you these exact steps in-app instead of silently retrying. WHOOP 4.0 is unaffected.

---

## 1.72 — GPS workout crash fix (Android)

- **Fixed (Android):** starting a GPS-tracked workout could crash the app on Android 12 and newer.
  GPS needs location permission, which NOOP never requested — and it was capped to older Android
  versions — so route tracking failed the instant it began. NOOP now asks for location permission
  right before a GPS workout and fails safe if it's unavailable: the workout still records heart rate
  and strain, just without a route. If you don't use GPS workouts, nothing changes. (Mac: version
  bump only.)

---

## 1.71 — GPS-tracked workouts (Android)

A community-requested feature, built on the v1.67 manual workout tracking.

- **Pick a sport on start.** Tapping "Start workout" opens a searchable picker (the Health Connect
  exercise-type catalogue, ~21 sports) + a "Track GPS route" toggle that defaults on for distance sports.
- **GPS route / distance / pace** via the platform `LocationManager` (no Google Play Services dependency).
  Live distance + pace show on the workout card; accuracy/teleport filtering via a pure `TrackFilter`.
- **Offline route drawing** — the route is stored as an encoded polyline (`WorkoutRow.routePolyline`,
  Room migration 3→4) and drawn on a blank Compose `Canvas` (`RouteCanvas`) — **no map tiles fetched.**
- **Health Connect writeback** — an `ExerciseSession` (+ `DistanceRecord`) on save, opt-in under Data
  Sources (unions `EXERCISE_PERMISSIONS` into the writeback request; non-fatal if not granted).
- New: `RouteMath` (Haversine/pace/polyline/normalize), `WorkoutSport`/`ExerciseTypes`, `LocationTracker`,
  `RouteCanvas`; `WhoopConnectionService` gains the `location` foreground-service type. Mac: version bump only.
- *Follow-ups:* per-session route on the Workouts screen; screen-off background tracking (dynamic FGS type).

## 1.70 — Clearer sync status + responsive Compare (#91, #93)

- **Android: sync is now visibly in progress.** The Live screen shows a plain "Syncing your strap
  history…" line while the strap offloads, instead of only a brief "· syncing" pill suffix that was easy
  to miss (#91, #93). `LiveScreen.kt`. Mac already surfaced this.
- **macOS: responsive Compare controls.** The time-range pills + Add menu now stack (`ViewThatFits`)
  instead of overflowing on a narrow window — ported from the iOS port's fix. `CompareView.swift`.

## 1.69 — Cleaner Live status + sync diagnostics (#91, #92)

- **Fixed (Mac + Android): "Last Event" no longer leaks plumbing.** The Live status field was showing
  the raw internal event `BLE_REALTIME_HR_ON` (truncated to "BLE_REALTIME_…") whenever live HR started
  — confusing (#92). Both platforms now skip the `BLE_REALTIME_HR_ON/OFF` stream toggle in that field;
  every meaningful event (wrist on/off, double-tap, battery, bonded…) still shows. Swift `FrameRouter`
  EVENT case + Android `WhoopBleClient` non-gesture branch.
- **Diagnostics (Mac + Android): dump rejected-frame hex.** Building on the v1.65 "decoded to 0 rows"
  WARNING — when a history chunk has frames that all fail to decode (CRC / unmapped firmware layout /
  out-of-range timestamp), the Backfiller now logs a hex sample of the first 3 rejected frames (≤64 B
  each). #91 is the first confirmed in-the-wild case (Moto Razr fold, WHOOP 4, layout the v1.66 fallback
  didn't catch) — the count alone can't be decoded, but the bytes let us map the firmware's layout.
  `Backfiller.swift` + `Backfiller.kt` at the WARNING site.
- **Docs:** corrected the stale "macOS AI Coach is sandbox-blocked" claim in README + PRIVACY_SECURITY —
  the distributed macOS build is unsandboxed, so the opt-in Coach works on both platforms.

## 1.68 — Sleep figures, HR zones, charging, calibration (thanks iHateSubscriptions, #88)

A large community contribution (#88), reviewed hard and reimplemented as our own commit onto v1.67.
Eleven small features from a gap analysis against the official app; adopted on both platforms after a
full build-verify (Android suite green, both Swift packages + the macOS app target compile).

- **Imported per-workout HR zones** (Mac + Android): a new "HR Zones" card on Workouts — time-in-zone
  for imported sessions, duration-weighted aggregate labelled approximate. Both parsers tolerate both
  stored key shapes (`z1..z5` Mac / `zone1..zone5` Android).
- **Charging indicator** (Mac + Android): the already-decoded BATTERY_LEVEL charging bit surfaced as a
  "· Charging" suffix on the battery pill; freshness-gated on Android, cleared on disconnect.
- **Prefer imported WHOOP sleep figures** (Mac + Android) on the headline tiles
  (`sleep_performance`/`sleep_consistency`/`sleep_need_min`/`sleep_debt_min`), with the on-device
  APPROXIMATE recompute as fallback. Android premise fix: `parseCycleSeries` now lands those four keys
  as `metricSeries` rows the Explore/Compare UI already referenced but nothing wrote.
- **Real hypnogram** (Android): the Sleep hero renders the stager's persisted per-epoch segments.
- **Recovery cold-start "Calibrating — N of 4 nights"** (Mac): Today ring + synthesis card; retires the
  misleading "0 DEPLETED" empty ring. Pure helper in `StrandAnalytics` (7 Android oracle cases ported).
- **Sync-status surfacing** (Mac): "History synced N ago" / stall warning in Today › Data Sources + the
  menu-bar popover; `relativeAgo` mirrored value-for-value with the Android twin.
- **Illness early-warning notification** (Mac): the opt-in toggle now posts a real system notification on
  the clear→raised transition, once per local day (Android already did). Fixed a double-`requestAuthorization`
  + day-key-set-inside-the-grant-callback bug found in review, so the once-per-day limit holds even if
  notifications were declined.
- **5/MG firmware alarm** (Mac): byte-identical to the hardware-confirmed Android rev-4 golden frame.
  **Experimental on WHOOP 5/MG** — arming is ACKed on hardware, a strap-driven wake-fire has not been
  captured yet; the smart-alarm card now says so. WHOOP 4 path byte-for-byte unchanged.
- **Cleanup**: removed the dead "light-sleep window" stepper (stored but never read — no wake-window
  watcher exists) and `Tools/translate-de.py` now pins UTF-8 (a Windows run had mojibaked the umlauts).
- **Kept the macOS AI Coach.** The contribution proposed removing it for an "offline by construction" Mac;
  we kept it instead — it's opt-in, bring-your-own-key, and works in the distributed (unsandboxed) build,
  so removing a working feature wasn't the right call. Privacy docs already describe it as the one
  transparent opt-in network exception. Gemini provider support (#89) is on the list, on both platforms.

## 1.67 — Manual workout tracking (Mac + Android)

- **New feature: start/stop a workout yourself** (top Reddit request). A "Start workout" button on the
  Live screen (shown when a strap is streaming) opens a live card — elapsed clock, current HR, avg,
  peak, and **strain building in real time** — with an "End workout" button.
- **Built entirely on existing primitives** (no new storage/analysis): captures the smoothed live `bpm`
  into a buffer, scores the window via `StrainScorer.strain(hr:maxHR:sex:)`, and saves a `WorkoutRow`
  (`sport:"Workout"`, `source:"manual"`) via the existing `upsertWorkouts` path — so it appears in the
  Workouts view automatically. Not a double-count: the day's strain already counts that HR (same live
  stream the store persists); the row is a per-session annotation.
- macOS: `AppModel.startWorkout/endWorkout/captureWorkoutSample` (hooked into `ingestHR`) +
  `LiveView.workoutSection`. Android: the mirror on `AppViewModel` + `LiveScreen`. Single buzz on
  start, double on save; a too-short session (no HR captured) is discarded quietly.

## 1.66 — Android: WHOOP 4 unmapped-firmware fallback — the #77 fix

- **Root cause (found via the Goose-PR mining + a cross-platform audit): a real macOS-only fix that
  never reached Android.** macOS `PostHooks "historical_data"` falls back to the canonical **v24
  layout** for an unmapped firmware version and accepts it only if it decodes to physically-real data
  (|gravity|≈1g + plausible HR) — the issue-#30 fix. Android's `HistoricalStreams.decodeHistorical`
  did `histVersionLayout(version) ?: return null` with **no fallback**, so a WHOOP 4 reporting a
  layout version outside {5,7,9,12,24} had **every type-47 record dropped** → the offload "completed"
  (`HISTORY_COMPLETE`), the trim advanced, and **zero data persisted**. Exact match for the #77
  Samsung S23+/Android-16 symptom (sync runs, nothing shows).
- **Fix:** ported the macOS fallback to Android `decodeHistorical` — unmapped version → decode against
  HIST_V24 → keep ONLY if `|gravity| ∈ 0.8..1.2` and `hr ∈ 25..230`, else drop (same as before, never
  garbage). **Strictly dominant:** recovers data the gate proves real, mapped versions untouched, no
  scenario makes any user worse off. Pinned by `HistoricalFallbackTest` (3 cases: mapped still decodes;
  unmapped+real falls back; unmapped+garbage still rejected).
- macOS: **version bump only** (already had it via #30).

## 1.65 — Sync diagnostics: surface silently-dropped history (#77)

- **Observability only — no behaviour change.** `Backfiller.finishChunk` now logs when a chunk arrives
  with frames but `extractHistoricalStreams` returns **zero rows** — i.e. every type-47 frame was
  dropped (CRC fail / unmapped layout / out-of-range timestamp). Previously this acked the trim and
  advanced the cursor while persisting nothing, so a "zero data" strap log showed only healthy
  `acked chunk` lines and the silent loss was **invisible**. Now: `WARNING N frame(s) decoded to 0 rows
  (trim=X) — dropped (CRC/layout/timestamp); nothing persisted`.
- Wired both platforms: Android via a new `log` callback on `Backfiller`; macOS reuses the existing
  `Backfiller.log` sink (which already logs unmapped firmware *versions* — this adds the **aggregate**
  CRC-drop case). Added `Streams.isEmpty` (Swift) mirroring Android `StreamBatch.isEmpty`.
- **Deliberately NOT changed:** the ack/trim behaviour. Refusing to ack an all-dropped chunk would
  wedge the offload in a re-send loop if frames fail CRC systematically — that fix needs a confirmed
  root cause first (a Samsung S23+/Android-16 reporter on #77 is the live case). This release exists to
  make that root cause diagnosable from a user's strap log.

## 1.64 — Android: MTU 247, skin-temp, sync status, recovery UI, alarm groundwork (thanks iHateSubscriptions, #85)

Reimplemented (NoopApp-authored, per our external-contribution policy) from PR #85, rebased on v1.62.
Reviewed part-by-part against current main + the objectivity discipline. **Adopted 4, modified 1, held 1.**

- **MTU 247 (adopt):** negotiate a larger ATT MTU on connect *before* service discovery — the default
  23 caps notifications at 20 bytes and fragments the type-47 offload. Gated discovery on
  `onMtuChanged` with a fallback timeout (a stack that ignores `requestMtu` can't stall connect); the
  once-only discovery kick is an `AtomicBoolean.compareAndSet` (API 26/27 deliver these callbacks on
  binder-pool threads, so the timeout and `onMtuChanged` race).
- **Sync status (adopt):** `lastSyncAt`/`lastSyncError` on `LiveState`, stamped in `exitBackfilling`
  by reason (`HISTORY_COMPLETE` → "History synced N ago"; `timeout` → a non-silent stalled-sync note).
  Pure `relativeAgo` helper + tests. Honest sync truth for a cloud-free app.
- **Skin-temp deviation, offline (adopt):** `AnalyticsEngine.wornNightlySkinTempC` (wear-gated —
  HR-concurrent, in-bed only, 28–42 °C so on-charger ambient drift can't poison the mean) feeds a
  two-pass personal baseline in `IntelligenceEngine` (mirrors avgHrv→recovery), re-deriving
  `skinTempDevC` — which re-arms the illness skin-temp signal. `/100` scale, APPROXIMATE.
- **Recovery cold-start UI (adopt):** `recoveryCalibrationNights` (counts nights with in-bounds HRV,
  matching `Baselines.update`'s validity predicate) → "Calibrating — N of 4 nights" on the ring,
  header and tile instead of a bare "No Data."
- **Named maverick buzz refactor (HELD):** **review catch** — the PR's `notificationBuzz(loops=1)`
  sets the `overallLoop` byte to 1, but our shipped golden frame
  (`…0113012f98…00…`, harshavin hardware-confirmed) has it **0**. The buzz already works; changing a
  proven payload for a refactor is regression risk for zero user value. Kept our inline buzz.
- **5/MG firmware alarm (MODIFIED — experimental-gated):** adopted `AlarmPayload` (`SET_ALARM_TIME`
  rev4 + `DISABLE_ALARM` rev2) + byte-exact tests, and wired `armStrapAlarm`/`disableStrapAlarm` for
  5/MG. But the rev4 layout is **unconfirmed on our side** (no captured `STRAP_DRIVEN_ALARM_EXECUTED`)
  and our own notes deferred it — so arming is **gated behind the Experimental probes opt-in**, not
  the plain smart-alarm toggle: a normal user can never rely on an alarm that might silently not fire,
  while opted-in testers can verify it. (`SET_ALARM_TIME`/`DISABLE_ALARM` added to the 5/MG allowlist.)
- macOS: **version bump only.**

## 1.63 — Mac: strap-computed nights show in Sleep (#77)

- **Fixed (macOS): BLE-computed nights vanished from the Sleep tab** (found from RolandGao's #77
  question "why is last night's analysis in Intelligence instead of Sleep?"). Root cause: TWO
  `stagesJSON` formats exist — imported nights store a **dict of minutes** (`{"light":N,…}`), while
  on-device computed nights store a **segment array** (`AnalyticsEngine.encodeStages` →
  `[{start,end,stage}]`). `SleepView.decodeStages` only parsed the dict, and `latestNight` returned
  nil on failure → **the whole "last night" hero disappeared for Bluetooth-only users** while
  Intelligence (reading DailyMetric) showed the night fine. Fix: `decodeSegments` parses the array
  (mapping the stager's "wake"→awake), and `Night.realSegments` feeds the hypnogram the GENUINE
  timeline for computed nights — strictly better than the synthetic "plausible architecture"
  reconstruction imported nights still get (the export has no per-epoch timeline).
- Android already handled both shapes (`SleepScreen.kt` tries JSONObject then JSONArray) — **version
  bump only.**

## 1.62 — WHOOP 5/MG history: the missing clock (thanks tajchert, #78)

Reimplemented (per our external-contribution policy) from **tajchert's hardware-validated fork branch**
(`whoop5-android-history-sync`), reviewed by a 29-agent adversarial workflow against our v1.61: 25
recommendations verified → 9 adopted, 26 already-superseded, 1 rejected (his CCCD reordering would have
killed standard-0x2A37 live HR).

- **THE unblock — clock before history (Mac + Android):** an un-clocked WHOOP 5 does NOT save sensor
  data to flash (firmware console: "RTC timestamp … is invalid; not saving data to flash"), so offloads
  "succeeded" with metadata only. NOOP now sends SET_CLOCK/GET_CLOCK (WHOOP4's 8-byte payload over
  puffin framing — strap-acked on hardware) after the puffin CCCD drain, before SEND_HISTORICAL_DATA.
  His hardware: 0 → 246 HISTORICAL_DATA frames. Android relocates the post-bond kick to the CCCD-drain
  completion; macOS clocks inside the once-per-connection `whoop5SessionStarted` gate.
- **GET_DATA_RANGE gating, fail-OPEN (Android):** query the stored range first, fire the transfer on
  SUCCESS (result codes 0–3 now decoded; PENDING precedes SUCCESS), 2s fallback because real hardware
  sometimes swallows the first query; one zero-frame retry per connection. Family-aware response offset
  (cmd@10 on 5/MG vs @6 — `strapNewestTs` never updated from 5/MG replies before).
- **5/MG decoders (Android parity + new):** COMMAND_RESPONSE (resp_cmd@10/seq@11/result@12),
  EVENT (+4, payload preserved as hex; BATTERY_LEVEL fields mirrored from Swift), CONSOLE_LOGS
  (UTF-8 @21, 2KB cap) — the strap's console now lands in the strap log ("strap: BLE: PullStats…").
- **Opt-in 5/MG raw capture (Android, default OFF):** `BackfillCaptureJsonl/Summary` (adopted verbatim —
  pure, tested) + append/rotate writer (40k lines/10MB; his truncate-per-session lost overnight data) +
  Settings toggle + consent-headed share sheet. This is the crowdsourcing pipeline for the puffin
  biometric decode (his captures show bulk type-54 = PUFFIN_EVENTS_FROM_STRAP per our PROTOCOL.md, still
  unclassified payload-wise).
- **Post-commit scoring (Android):** a committed backfill chunk schedules a debounced (1.5s)
  `IntelligenceEngine.analyzeRecent` + HC-writeback — fresh history scores in seconds, and scores at all
  in background-only operation (the 15-min loop lives in the Activity-scoped ViewModel).
- **Direct-connect to the OS-bonded 5/MG (Android):** skips the scan (hardware showed first protected
  GATT op failing status=133 on scan-reconnects); stale bonds fall back to a scan via handleDisconnect.
- **isOffloadFrame accepts type 52** (HISTORICAL_IMU_DATA_STREAM) for 5/MG. His EVENT/CONSOLE_LOGS
  progress-counting *removal* is NOT adopted — needs hardware validation (watchdog semantics).
- **Tests:** 4 real-hardware vectors (CRC-pinned Goose command frames, event 0x1D, console text,
  ACK-capture v18 frame: HR 66 / skin 32.38°C / |g|≈1) + capture encoder/summary suites — all green.
- Model selection now survives restarts even with background connection off.

## 1.61 — Android: the widget now actually updates (#82, second find)

- **Fixed: widget starvation under live HR.** The reporter's follow-up symptoms (live HR fine in-app,
  widget frozen at "♥ —"/"⚡ —" with "Connected" underneath, surviving re-adds and reboots, on a Pixel)
  pinned a textbook coroutine bug: the service collected the notification/widget stream with
  **`collectLatest`, whose body is cancelled on every new emission** — and `WidgetSnapshotStore.push()`
  suspends in Glance machinery (`getGlanceIds` + `updateAll`) longer than the ~1 s live-HR emission
  interval. Once streaming started, **every push was cancelled mid-flight, forever**; only the sparse
  post-connect pushes (connected=true, HR/battery not yet present) ever completed — exactly what the
  widget showed. Compounding it, the throttle marked `lastPushAtMs` BEFORE the write, so each doomed
  attempt also burned the 60 s refresh window. The notification was immune (synchronous post).
- **Fix:** `conflate()` + `collect` (process the latest value, never cancel in-flight) + throttle
  decision extracted to a pure `PushGate` (mark **after** save; save **before** the placed-widget
  check so a widget added later renders fresh data; **HR-presence joins the key** so the first sample
  pushes immediately instead of waiting out the window). Regression-pinned by `PushGateTests` (7 tests).
- macOS: **version bump only.**

## 1.60 — Android: notification recovery fix + widget armour (#82)

- **Fixed: the v1.56 notification Recovery %** — `buildNotification` accepted the value but the
  display line was never added, so it computed and silently dropped it. Now rendered ("Recovery NN%"
  between status and battery).
- **#82 ("app keeps stopping" after first widget add, v1.57) — investigated to the metal, NOT
  reproducible:** 10-agent adversarial workflow decompiled Glance 1.1.0's full exception flow
  (receiver `goAsync` catches Throwable→log; SessionWorker exceptions → WorkManager FAILED;
  composition errors → built-in error layout, default `errorUiLayout` is non-zero so the rumored
  rethrow path is unreachable) — **the Glance pipeline cannot kill the process**. Stood up a headless
  Pixel-6/Android-14 emulator and ran 12 scenarios on v1.59 **plus the exact repro on a fresh v1.57
  install** (real launcher drag-and-drop first-ever widget add → repeated app returns): zero crashes,
  stable PID. Verdict: environment-specific to the reporter's device, self-resolved after update;
  no behavioral change justified (objectivity rule).
- **Defence-in-depth shipped anyway** (belt-and-braces, honestly labelled): `.catch{}` on the
  service's notification combine (a Room error in `daysMergedFlow` WOULD have propagated uncaught out
  of `scope.launch` — real latent risk, just not #82), `onCompositionError` override rendering our own
  fallback layout (friendlier than Glance's generic one), `runCatching` around the widget's pref load.
- **Dependency currency:** `glance-appwidget` 1.1.0→**1.1.1**; explicit
  `androidx.work:work-runtime-ktx:2.9.0` pin (Glance's POM drags in 2.7.1 from Oct 2021 — pre-Android-14;
  2.9.x is the compileSdk-34 ceiling).
- macOS: **version bump only.**

## 1.59 — Android: share back to Health Connect (opt-in)

- **New (Android): Health Connect writeback** — new `HealthConnectWriter` pushes NOOP's **computed**
  nightly metrics (resting HR, HRV RMSSD, SpO₂, respiratory rate; last 60 days) into Health Connect.
  Two deliberate scope limits: **computed days only** (`repo.days(computedDeviceId)` — imported
  WHOOP-export/HC rows are never echoed back, which would duplicate another app's data or loop our own
  import), and **idempotent by `clientRecordId`** (`noop-<metric>-<day>` + write-time
  `clientRecordVersion`, because HC does NOT auto-dedupe re-inserts the way HealthKit does — the
  latest computation always wins, no stacking). Four `WRITE_*` permissions added to the manifest,
  requested only when the user opts in; denial flips the toggle back off. **Default OFF** — "Share
  back to Health Connect" toggle in Data Sources; while on, every 15-min recompute re-writes
  (runCatching-guarded so an HC hiccup never breaks the analysis loop).
- macOS: **version bump only.**

## 1.58 — Android: bottom tab bar

- **New (Android): bottom `NavigationBar`** — Today / Trends / Live / Sleep as permanent tabs, plus a
  **More** tab opening a `ModalBottomSheet` that renders the *same* `drawerGroups` the hamburger drawer
  shows (verbatim — one source of truth, both routes reach every screen). The drawer is kept untouched
  for reversibility; the bar is purely additive. The More tab lights up whenever the current screen
  isn't one of the four tabs, so the bar never shows "nowhere". All navigation through the existing
  `navigateTopLevel` (single-top + state save/restore — back behaves the same).
- macOS: **version bump only.**

## 1.57 — Android home-screen widget

- **New (Android): home-screen widget** — today's recovery (band-coloured 67/34), live HR and strap
  battery, tap-to-open. New `com.noop.widget` package on Glance (`glance-appwidget:1.1.0`, the last
  line compatible with compileSdk 34): `NoopGlanceWidget` renders purely from a SharedPreferences
  snapshot (no BLE/DB at compose time, survives process death), `WidgetSnapshotStore.push()` throttles
  (meaningful-change immediate, HR at most 1/min — Glance re-inflation is far heavier than a notify())
  and no-ops when no widget is placed. Two producers: `WhoopConnectionService`'s v1.56 combine (the
  heartbeat while the UI is closed) and `AppViewModel.recentDays` (foreground with the service off).
  `updatePeriodMillis=0` — push-only, the OS never polls. Receiver `exported="true"` as the launcher
  requires.
- macOS: **version bump only.**

## 1.56 — Shortcuts on Mac, recovery in the Android notification

- **New (macOS): App Intents / Shortcuts actions — "Buzz Strap" and "Mark a Moment."** New
  `Strand/System/NOOPAppIntents.swift` exposes both as `AppIntent`s with an `AppShortcutsProvider`, so
  they're available from Shortcuts.app, Spotlight, and menu-bar/keyboard triggers without opening the
  window. They reach the live bonded strap via a new `static weak var AppModel.shared` (published in
  `AppModel.init`) — constructing a fresh `AppModel` from an intent would spin up a second BLEManager +
  analysis loop and could never buzz. Guarded: a fired intent with NOOP closed throws "open NOOP first";
  with the strap unbonded, "connect your strap." macOS 13+, **no new entitlement or Info.plist key**.
  The inbound counterpart to the existing outbound double-tap→Shortcut path (#42 idea-mining).
- **New (Android): today's recovery % in the foreground-service notification.**
  `WhoopConnectionService` now `combine`s `ble.state` with `repo.daysMergedFlow("my-whoop")` and appends
  "Recovery NN%" to the ongoing notification's detail line (alongside live HR + strap battery). It
  re-posts when the 15-min `IntelligenceEngine` recompute lands, and stays absent until enough nights
  are scored. `runCatching`-guarded; near-zero blast radius (notification copy only).

## 1.55 — Mac: recovery builds from your strap alone (#78)

- **New (macOS): BLE-only recovery cold-start — parity with Android v1.53.** `IntelligenceEngine.swift`
  now runs **two passes** (harvest each offloaded night's baseline-independent avgHrv/restingHr, seed
  the baseline from the union of imported + on-device nightly values, re-score recovery). So a
  Bluetooth-only Mac user crosses `Baselines.minNightsSeed` (4 nights) and recovery lights up without a
  WHOOP import; honest-null until then; imported values still win per day (only-if-absent fill).
- **macOS: WHOOP5 `step_motion_counter` now persists** (`StepSample` in WhoopProtocol Streams + routed in
  `extractHistoricalStreams` + WhoopStore **v10 migration** — additive, no destructive fallback). Decoded
  but previously dropped on Mac. Surfaced later; still APPROXIMATE. `StepSampleTests` pins the round-trip.
- **Deferred (objectively): the skin-temp `/100` vs `/128` scale.** Both platforms store the **raw**
  register and both real frames sit in the *overlap* of the two gate bands, so it's a **latent**
  divergence, not a bug — and the obvious unification (`/128`, 20–45) would reject the off-wrist frame
  and break the wrist-contact parity test. Left as-is pending a real calibration decision.
- Android: **version bump only** — it already had recovery seeding and step persistence (v1.53).

## 1.54 — French WHOOP exports now import (#79)

- **Fixed: a French WHOOP export imported 0 items.** Third localisation after German (#3) and Spanish
  (#76). A French export translates **both** the column headers (`Score de récupération %`,
  `Variabilité de la fréquence cardiaque (ms)`, `Durée du sommeil paradoxal (min)`, …) **and** the
  sleep/workout filenames (`sommeil.csv`, `entrainements.csv`) — so nothing matched.
- NOOP now maps the **full** French column set, including the complete **workouts** file (HR zones,
  activity name/strain) — the reporter supplied all three header rows, so French is more complete than
  Spanish out of the gate. Two French quirks handled by the normaliser (both fold to `_`): the
  apostrophe in `Niveau d'oxygène` / `Temps d'éveil` (straight `'` **and** curly `’`), and the
  **non-breaking space** before `%` in the `Zone FC 1 %` workout headers. `physiological_cycles.csv`
  keeps its English filename but French columns; both handled. Mac + Android. Real-header parse +
  normalisation tests pin it (incl. the apostrophe + NBSP cases); verified with `swift test`.

## 1.53 — Recovery builds from your strap alone, Android (#78)

- **New (Android): BLE-only recovery cold-start.** The recovery baseline only ever seeded from
  *imported* nightly history, so a Bluetooth-only user (no WHOOP CSV) never crossed
  `Baselines.minNightsSeed` (4 valid nights) and recovery stayed blank forever — even with offloaded
  nights sitting in the store. `IntelligenceEngine` now runs **two passes**: pass 1 computes each
  offloaded night's baseline-*independent* aggregates (avgHrv / restingHr via SleepStager+AnalyticsEngine),
  pass 2 seeds the baseline from the **union of imported + on-device nightly values** and re-scores only
  the cheap recovery composite. So recovery lights up from the strap's own nights after ~4 nights; it
  stays honestly null until then; a real import still wins per day. The natural payoff of v1.52's offload.
- **Under the hood (landed dark — computed/stored, not yet surfaced, pending hardware validation):**
  - `stepSample` table + `dailyMetric.steps` / `activeKcalEst` columns via a **real additive Room
    migration** (`MIGRATION_2_3`). **The `.fallbackToDestructiveMigration()` is removed** — with
    `exportSchema=false` a hand-written-SQL mismatch would otherwise *silently wipe* already-acked,
    non-resendable strap history; now Room throws loudly instead. The migration SQL was **verified
    byte-for-byte against Room's generated schema** before shipping.
  - The WHOOP5 `step_motion_counter@57` (decoded but previously dropped) now persists; `AnalyticsEngine`
    derives a daily step total + an APPROXIMATE whole-day HR→energy estimate; detected workouts persist
    under the `-noop` id (deduped against imported workouts). All clearly APPROXIMATE; **the steps tile
    stays dark** until @57's semantics are validated against the official app.
  - **Fixed a respiratory-rate band mismatch:** `SleepStager.respRateFromRR` could emit 6–8 bpm, but every
    consumer (`ReadinessEngine` illness/readiness) only acts on 8–25 — so a sub-8 estimate was
    persisted-then-silently-ignored. The band is now a single canonical source (`respPlausibleRangeBpm`,
    owned by the producer, referenced by the consumer); RSA NaNs anything outside it before persisting.
  - Conservative resp gates (size ≥ 10, raised z-thresholds, 2+ flags to fire) so the noisier on-device
    RSA can't trip false illness/readiness flags.
- Reimplemented onto current main from community PR #78 (credited), with the migration-safety + RSA-band
  fixes applied. v1.48–1.52 work untouched.
- macOS: **version bump only** — it has the same single-pass-baseline gap; recovery-seeding parity is a
  tracked follow-up.

## 1.52 — WHOOP 5.0/MG history offload, Android (#78)

- **New (Android, experimental): WHOOP 5.0/MG historical offload** — Android reaches parity with the
  Mac, which already had this. A 5/MG can now download its stored history (not just stream live HR),
  which is what feeds recovery / strain / sleep.
- **The fix that made it actually work.** The 5/MG "puffin" envelope shifts the inner record **+4** vs
  4.0, and its HISTORY_END/COMPLETE marker is **`PUFFIN_METADATA` (type 56)**, not 49. Android's
  offload-frame check read `frame[4]` with `{47,48,49,50}` — so on a real strap **every** history-closing
  frame was dropped as live-flood, no chunk ever committed, the strap never trimmed, and the offload
  idle-watchdog timed out: zero history. NOOP now reads the type at `frame[8]` for 5/MG and accepts
  `{47,48,49,50,56}` — matching the hardware-proven Swift path (`BLEManager.isOffloadFrame`,
  `BLEManager.swift:500`). Ported pieces: family-aware `isOffloadFrame`, `decodeMetadataWhoop5`
  (meta_type@10 / unix@11 / trim_cursor@21), `Backfiller.begin(family)` + `endData` (+4 → `frame[21:29]`),
  the 5/MG `send()` allow-list (`SEND_HISTORICAL_DATA` + `HISTORICAL_DATA_RESULT`, framed as puffin
  commands), and the 5/MG post-bond offload kick (the CLIENT_HELLO ack now marks the handshake done,
  which gates the offload). A new `Whoop5OffloadTest` pins the type-56 case the original PR's tests missed.
- **Experimental — please verify on a real strap.** The offsets are cross-confirmed (Swift + Linux tool +
  the hardware-anchored +4), but no captured 5/MG HISTORY_END frame exists in-repo, so 5.0/MG owners:
  please report whether your history actually populates end-to-end. Reimplemented from a community
  contribution (#78), credited; the v1.48–1.51 reliability work (write queue, resubscribe, sync pill,
  family-gated battery) is untouched.
- macOS: **version bump only** — its 5/MG offload path was already complete and hardware-verified.

## 1.51 — True battery %, a sync indicator, and HR on imported workouts (#77)

- **Fixed: battery flashing 100% then correcting (or reverting to 100%).** The WHOOP 4.0 exposes the
  standard Battery Level characteristic (0x2A19) but it's a **stub that always reports 100** — the real
  charge only comes from the proprietary `GET_BATTERY_LEVEL` response (u16/10). NOOP read **both** into
  the same display with no priority, so 0x2A19 landed first (100%) and the real value corrected it a
  beat later — and since 0x2A19 is also *subscribed*, a stray stub notification could revert a true 94%
  back to 100%. Battery now comes **only from the real source per family**: WHOOP 4 = the proprietary
  command; 5.0/MG = 0x2A19 (unchanged — its proprietary command isn't framed). On macOS this also stops
  the stub 100 polluting the low-battery alert hook. Mac + Android.
- **New: "Syncing strap history…" indicator** (Mac + Android). While a historical offload runs, Today /
  Sleep / Intelligence's empty states show a pulsing pill with a live **chunks-pulled count** (a count,
  never a percent — total pending is unknowable from the protocol), so "No nights here yet" mid-sync
  reads as in-progress rather than final. The Live pill shows **"Bonded · syncing"**. `LiveState` now
  publishes `backfilling` + `syncChunksThisSession` (Android republishes every 10th chunk so the
  foreground-service notification isn't re-posted at chunk rate); cleared on session end AND on
  disconnect so the pill can't stick on.
- **Fixed (Android): imported workouts showed no HR.** Health Connect `ExerciseSessionRecord`s carry no
  summary HR, so the importer stored `avgHr/maxHr = null` and the Workouts list rendered "–" forever.
  Two-part fix: (a) the **importer** now intersects each session's window with its `HeartRateRecord`
  samples (targeted per-session reads, one bad session can't fail the import) and stores real avg/max;
  (b) **display fallback** — Workouts/Today fill a null-HR imported session from the strap's own ~1 Hz
  samples over the workout window (new indexed `hrWindowStats` aggregate; ≥60 samples required so strays
  can't fabricate an average; display-only so a re-import can't be clobbered; capped per load). Demo
  flavor unaffected (its seeded workouts always carry HR).

- **Fixed (Android): sustained command-write congestion on slow GATT stacks.** A Pixel 7 on Android 16
  logged ~56 `writeCharacteristic busy` retries **and 6 hard `dropped after 6 retries`** in ten minutes
  (v1.48). Two changes:
  - **Bigger, escalating write-retry budget** — `MAX_WRITE_RETRIES` 6 → 12, and the backoff now grows
    per attempt (12, 24, … capped ~96ms) so a stack that's busy for a while gets time to clear instead
    of exhausting the budget in ~70ms. Nothing hard-drops.
  - **Re-subscribe at most once per quiet episode.** The keep-alive re-subscribed all notify chars on
    every 30s tick while the stream was quiet, flooding descriptor writes that collide with the command
    queue (Android serves **one** GATT op at a time across reads/writes/descriptors). It now re-subscribes
    once per quiet spell and re-arms when data next arrives — a dropped CCCD is still recovered, the churn
    is gone.
- Context (from #77): the "no overnight scores" reports are usually an **empty strap buffer** — the
  official WHOOP app, bonded overnight, trims the strap's history as it syncs, so NOOP finds little to
  offload. The reliable history path is the WHOOP CSV import. This release fixes the *separate* congestion
  bug those logs surfaced.
- macOS: **version bump only** (CoreBluetooth queues GATT ops internally).

- **Fixed: a Spanish WHOOP export imported 0 items.** WHOOP's Spanish export translates **both** the
  column headers (`Puntuación de recuperación (%)`, `Variabilidad de la frecuencia cardíaca (ms)`, …)
  **and** some filenames (`sueño.csv`, `entrenamientos.csv`) — so the filename match missed the sleep/
  workout files and the column match missed every translated header, giving "Imported 0 items."
- NOOP now maps the full set of Spanish column headers (supplied from a real export, #76) onto the
  canonical fields, and recognises the Spanish filenames — so recovery, RHR, HRV, skin temp, blood
  oxygen, day strain, every sleep stage, nap, etc. all import. `physiological_cycles.csv` keeps its
  English filename in the Spanish export but its columns are Spanish; both cases are handled. The
  content-sniffer also classifies the Spanish sleep file by its (now-aliased) columns.
- Same approach that added German (#3). Workout column names are inferred from WHOOP's consistent
  Spanish pattern; an unmatched alias simply never fires, so it's safe. Mac + Android. A real-header
  parse test pins the values. Verified with `swift test`.

- **Fixed (Android): dropped Bluetooth commands on stricter stacks (Android 13+, worst on Android 16).**
  When the phone's GATT stack was momentarily busy it would reject a command write, and NOOP **dropped**
  it instead of retrying. The dropped frame was often the one that **starts live HR**, **sets the strap
  clock**, or **acks a history chunk** — so live HR sometimes never started and overnight data never
  landed, even with a healthy strap and pairing. NOOP now **retries a rejected write** (bounded backoff,
  preserving command order) and **paces** without-response writes so the stack keeps up.
- Diagnosed from a detailed strap log: a Pixel 7 on Android 16 whose offload completed cleanly but whose
  `TOGGLE_REALTIME_HR` / `SET_CLOCK` writes were being rejected and dropped.
- macOS: **version bump only** — it relies on CoreBluetooth's own write queue and was never affected.

## 1.47 — Auto-sync Health Connect (Android)

- **Opt-in Health Connect auto-sync (Android).** Turn it on under Data Sources → Health Connect and NOOP
  re-pulls new Health Connect data (e.g. a Samsung Galaxy Watch → Samsung Health → Health Connect) each
  time you open the app, if the last sync is older than your chosen **6 / 12 / 24h** interval. Read-only,
  idempotent, **never overwrites richer strap data**, **default OFF**. Adopted from a community PR.
- Deliberately **on-open only** (no background worker): the contributed version also added a WorkManager
  background job, but that's best-effort on Android 14+ and needs a sensitive background-health
  permission — so we took the reliable foreground catch-up and skipped the worker + the permission.
- macOS: **version bump only** (HealthKit doesn't exist on macOS; the Mac path stays the export import).

## 1.46 — Revived-strap history dates, gestures during sync, clearer pairing state

- **Stale-strap clock correction (#72).** A strap that sat unused has a drifted RTC, so its offloaded
  history landed months in the past — live HR worked, but recovery/strain/sleep never showed as "today."
  `extractHistoricalStreams` now corrects type-47 + EVENT timestamps by the strap-vs-real clock offset
  **only when the strap clock is clearly stale (>1 day off)**, snapped to a 5-min grid so the correction
  is deterministic across re-syncs (rows dedupe by timestamp). No-op for a normal strap. Both platforms.
- **Live gestures during a history sync (#69).** `isOffloadFrame` classed EVENT(48) as bulk-sync
  traffic, so during a backfill a real-time double-tap / wrist event was routed to the sync handler and
  never fired — for minutes at a time on a 5.0/MG. NOOP now fires live gestures even mid-sync, gated on
  the event being recent **in the strap's own clock domain** (macOS) so a *replayed historical* gesture
  from the offload doesn't fire; Android fires live gestures ungated and gates only during a backfill.
- **"Encrypted bond" vs "live HR" indicator (#69).** On a 5.0/MG, live HR streams over the open
  Bluetooth profile without a real encrypted bond, so the app used to say "Bonded" when it wasn't. The
  Live pill now shows **"Bonded"** only for a genuine encrypted bond, else **"Live HR (not fully
  paired)"** — the encrypted bond is what unlocks buzz, alarms, double-tap and history sync. The in-app
  pairing tip now mentions tapping the band to enter 5.0/MG pairing mode. Both platforms.
- _Known, tracked limitations:_ a strap that's both clock-stale and mid-offload may miss a double-tap
  during that sync window on Android (no GET_CLOCK correlation to gate in the strap's clock domain); and
  a record re-offloaded across a successful SET_CLOCK could store twice (proper fix = persist the
  per-device offset). Both narrow.

## 1.45 — Clearer pairing guidance for WHOOP 5.0/MG (Mac, #69)

- **A 5.0/MG streams live heart rate before it's fully (encrypted-)paired** — and buzz, alarms,
  double-tap and full history sync all need that real pairing. NOOP now keeps the "free the strap
  from the WHOOP app" guidance visible (in clearer wording) whenever the strap isn't fully paired,
  instead of hiding it once live HR appears — so it's obvious what to do to unlock the rest (#69).
- This **reverts v1.44's over-eager hint-clearing**: on a 5/MG, `bonded` is also set by the live-HR
  shortcut (HR rides the unbonded standard profile), so clearing the hint there hid the *accurate*
  "free the strap" guidance from users who were streaming HR but never got the real encrypted bond.
  The hint now only clears on a genuine bond (the `CLIENT_HELLO` ack) or a fresh connect attempt, and
  the banner is reworded from "Pairing refused" to guidance.
- Android: **version bump only** (the banner is macOS-only).

## 1.44 — Fixes a false "pairing refused" warning (Mac, #69)

- **The "Pairing refused" banner no longer cries wolf on a working connection** (Mac). It could stay
  up on the Live screen even after the strap had bonded and live heart rate was streaming — a stale
  warning on a link that was actually fine (reported by a 5.0/MG owner, #69). `LiveState.pairingHint`
  now clears on every bond-completion path (a `didSet` on `bonded`), so it disappears the moment the
  link bonds.
- Android: **version bump only** (the banner is macOS-only).

## 1.43 — 24-hour heart-rate trend on the dashboard

- **See your whole day's heart rate on Control Center** (Mac + Android). A new full-width trend plots
  your continuous heart rate across today, read straight from the strap's own ~1 Hz history — so it
  fills in even for the hours the app was closed, not just while it's open.
  - **Downsampled in SQL**: a fully-worn day is ~86k samples at 1 Hz, so the chart reads 5-minute
    bucket means (`GROUP BY ts/300`) rather than loading every row — a new `hrBuckets()` on both the
    GRDB store and the Room DAO. The day's low / average / high sit under the chart.
  - Hidden until there's wear today, so a strap with no readings yet shows nothing rather than an
    empty axis. Works on WHOOP 4.0, and on 5.0/MG (its live HR feeds the trend too).

## 1.42 — Auto-reconnect to your strap on launch (Android, #67)

- **NOOP reconnects to your strap automatically when the app starts** (issue #67 — jamartif: after an
  APK update the band stayed disconnected until you tapped Connect). The process restart on an update
  (or any cold launch) left the app disconnected because there was **no auto-connect on launch** and
  **no persisted strap** — every `connect()` was user-tapped, and the v1.36 reconnect used an
  in-memory device that's gone after a restart.
  - **Persist the bonded strap**: `NoopPrefs.setLastDevice(address, model)` on the bonded transition
    (on-device only, never sent); cleared on a model switch.
  - **Reconnect on launch**: `AppViewModel.autoReconnectOnLaunch()` (called from `init`) →
    `WhoopBleClient.reconnectToAddress()` does a direct `connectGatt(autoConnect=true)` to the saved
    strap — no scan; the OS connects as soon as it's in range. Gated on **"Keep connected in the
    background"** + a previously-bonded strap; no-ops if already connected or the runtime BT permission
    isn't granted.
- macOS: **version bump only.** It has the same gap (CoreBluetooth state restoration isn't actually
  enabled — `CBCentralManager` is created without a restore identifier), but it's lower-value there (the
  menu-bar app stays alive, updates are infrequent) and adding it needs a gating decision (no
  keep-connected pref exists on macOS). Tracked as a follow-up.

## 1.41 — Update check shows what's new

- **The "Check for updates" result now previews what's new.** When a newer version is found, the
  result expands to show the release's notes (the changes, with the Downloads/footer boilerplate
  trimmed and the heaviest markdown stripped, capped + scrollable) alongside the Download button — so
  you can see what you're getting before tapping through. The `body` is already in the
  `releases/latest` response, so this is the same single request; `cleanNotes()` does the trimming on
  each platform. No new network behaviour.

## 1.40 — Check for updates (both platforms)

- **New: a manual "Check for updates" button** in Settings → About. One user-initiated GET to the
  PUBLIC GitHub releases API (`api.github.com/repos/NoopApp/noop/releases/latest`) — compares the
  `tag_name` to the installed version and, if newer, shows a Download button that opens the release
  page; otherwise "You're on the latest." Graceful failure on offline/rate-limit. **No background
  polling, no auto-update, nothing about the user is sent** — it only runs on tap, and only reads a
  version number.
- **Version comparison is unit-tested** on both platforms (`VersionCheck.isNewer` in WhoopProtocol;
  `UpdateCheck.isNewer` on Android) — it compares dot-separated numeric segments so `1.40 > 1.39` and
  `1.9 < 1.10` (a plain string compare gets both wrong), tolerant of a leading `v` and the demo
  flavour's `-demo` suffix.
- **macOS posture note:** this is the first feature to make an outbound connection, so the macOS
  sandbox entitlement `com.apple.security.network.client` was added. It's used only for this
  user-tapped check and the opt-in, off-by-default AI Coach — there is no automatic/background traffic.
  Android already declared `INTERNET` (for the opt-in Coach), so it needed no change.

## 1.39 — Wrist alerts for incoming calls (Android, #66)

- **Buzz on incoming calls** (community PR #66 by DieserLiton; reimplemented as NoopApp). A dedicated
  **Calls** section in Notifications settings, separate from per-app alerts:
  - **Native phone calls** via a `PhoneCallReceiver` (READ_PHONE_STATE), and **best-effort VoIP** via the
    existing notification listener (`VoipCallClassifier`, an 8-app allowlist). One coordinator
    (`CallAlertController`) drives a bounded repeat cadence — immediate, then every 8s, max 4 buzzes.
  - **Privacy contract intact** — reads only the phone *state* string (`RINGING`/`OFFHOOK`/`IDLE`, never
    `EXTRA_INCOMING_NUMBER`) and a tiny set of notification *metadata* (package / `CATEGORY_CALL` / flags),
    never the number, caller, title, text, or extras; no `READ_CALL_LOG`/`READ_CONTACTS`; nothing
    sensitive logged. `READ_PHONE_STATE` is requested **only** when the user enables "Phone calls".
  - Reuses the shared component system; the existing per-app wrist-alerts are untouched.
- **Two correctness fixes applied on adoption** (from the review):
  - `CallAlertController` now has a **self-healing 60s max-ring watchdog** — a dropped `PHONE_STATE=IDLE`
    broadcast or a missed `onNotificationRemoved` could otherwise leak a token and silently kill the next
    call's alert until a process restart. It auto-clears (re-armed on each sign of life).
  - An incoming VoIP call is now routed to the **Calls path only** (always returns), so a call from an app
    that's also enabled as a per-app alert can't **double-buzz**.

## 1.38 — Responsive during long history syncs (Mac, #64 / #65)

- **Mac stays responsive during long historical offloads and dashboard analysis** (community PRs #64,
  #65 by rr-allin; both verified against current `main`, symbols + the buzz path intact):
  - **#64 (`BLEManager.swift`)** — offload frames are treated as bulk sync, not live UI traffic:
    during a backfill, type-47/48/49/50/56 frames bypass the live `FrameRouter` and feed only the
    `Backfiller`, drained in small batches (12) with `Task.yield()` between slices so SwiftUI can
    paint. HISTORY_END ack logging is throttled (ack #1, then every 25th). `beginBackfill()` now
    returns whether it actually started, so a deferred backfill no longer stamps `backfillLastAt`
    (which would rate-limit a sync that never ran). Live HR (type-40) and the GET_DATA_RANGE liveness
    watchdog still flow through the live path — unaffected.
  - **#65 (`AppModel.swift`, `IntelligenceEngine.swift`)** — a completed backfill now refreshes the
    dashboard cache (`repo.refresh(days: 120)`) instead of immediately running full analysis;
    `analyzeRecent` early-returns if an analysis is already in flight (guarded on the existing
    `computing` flag); `AnalyticsEngine.analyzeDay` runs in a utility-priority detached task with a
    `Task.yield()` between days — so the heavy recovery/strain/sleep compute no longer stalls the main
    actor.
- Mac-only changes; Android gets the lockstep version bump.

## 1.37 — New first-run onboarding, Mac + Android parity (#36 / #63)

- **A unified 11-step first-run onboarding** on both platforms (Welcome · What it does · Expectations ·
  Bluetooth · Wear · Connect/Scan · **Bonded** celebration · Profile · Import · **Notifications** · Done),
  reimplemented from community PR #36 (by Brechard; design in #63). Highlights:
  - **Contextual permissions (Android)** — nothing fires at launch; Bluetooth is requested only when
    leaving the "before you connect" screen, scanning goes through the shared `BlePermissions.kt` gate
    (the same one Live/Settings use), and notifications are requested on the Notifications step's CTA.
  - **Bonded celebration** auto-advances once the strap bonds (skipped when nothing is bonded); the
    **foreground-connection service is promoted only on completion**, not mid-flow.
  - **Parity/polish** — config-change-safe nav (`rememberSaveable`), typed import-failure styling on both
    platforms (incl. a macOS Data Sources green-on-failure fix), `+/−` steppers for the profile (the two
    `StepperField`/`StepperButton` helpers promoted from Settings into the shared `Components.kt`), shared
    component system + `Metrics.*` spacing, chrome uses `accent` rather than the data-reserved recovery ramp.
  - Verified on adoption: every recent fix survives untouched (HR-spike smoothing #46, smart-alarm bond
    re-arm #59, the Re-scan permission gate #1, the buzz), the `connect(promoteService:)` change is
    backward-compatible, and the unused `GhostButtonStyle` was dropped.
- **Live HR zones use your real max heart rate.** `HealthScreen` now reads `ProfileStore.hrMax` (your manual
  override, else the age-based Tanaka estimate) for live zone/%-max instead of a hardcoded `190` — committed
  separately from the onboarding change.

## 1.36 — Android: direct reconnect after a dropout (#61)

- **Fixed (Android): a dropped WHOOP 4.0 could get stuck "disconnected" and never reconnect** (issue
  #61). `handleDisconnect` only ever called `connect()` → a BLE **scan**, but a bonded strap that the
  OS still holds (or that simply isn't advertising) doesn't show up in a scan — so it looped
  `No WHOOP strap found` until the user forced the strap into pairing mode. Now the client **remembers
  the connected `BluetoothDevice`** and, on an unintentional drop, reconnects to it **directly** via
  `connectGatt(autoConnect = true)` — the OS reconnects as soon as the strap is reachable, with no
  scan and no advertisement needed. `connectToDevice` gained an `autoConnect` param (default `false`
  for the scan-discovered first connect) and now closes any stale GATT first; `prepareForModelSwitch`
  clears the remembered device so a model switch scans fresh.
- macOS already did this — `connect()` reconnects via `retrieveConnectedPeripherals` + `central.connect`
  (and state-restoration) before falling back to a scan — so this is an **Android-only** fix +
  lockstep version bump.

## 1.35 — WHOOP 5/MG buzz matched byte-for-byte (#48)

- **WHOOP 5.0/MG haptics now byte-identical to a working app.** v1.34 fixed the opcode (`0x13`) but
  kept the WHOOP-4.0 payload. The contributor's working 5.0 app ("whootify") was decompiled, giving
  the real command:
  - **Payload**: `[0x01, effects(8), loopControl(u16 LE), overallLoop]` — 12 bytes. We send the
    "notify" preset (effects `47,152`): `01 2f 98 00 00 00 00 00 00 00 00 00`.
  - **Framing fix — `pad4`**: the strap's maverick framing pads the inner record to a 4-byte boundary
    before length+CRC. `puffinCommandFrame` *wasn't* doing this — it didn't matter for the 4-aligned
    commands shipped so far (toggle-HR, historical), but the 12-byte haptic inner is 15 bytes and must
    pad to 16, or the declared length + CRC32 are wrong and the strap rejects the frame. Added pad4 to
    `puffinCommandFrame` on both platforms (no-op for the aligned commands — existing frames unchanged).
  - **Verified byte-for-byte**: a golden-vector test on each platform asserts `puffinCommandFrame(0x13,
    seq=1, notify-payload)` equals the frame the working app's `buildMaverickFrame` produces
    (`aa0114000001e1e1230113012f98…98cb83a5`), and that pad4 leaves HR-toggle's frame at 16 bytes.
- So a bonded 5.0/MG should now actually vibrate on Test buzz / wrist alerts / smart-alarm buzz.
  **WHOOP 4.0 buzz is byte-for-byte unchanged** (still opcode 79 + its own frame). Awaiting hardware
  confirmation on #48.

## 1.34 — WHOOP 5/MG haptics opcode (experimental, #48)

- **Experimental (WHOOP 5.0/MG): buzz now sends opcode `0x13`, not the 4.0 `RUN_HAPTICS_PATTERN`
  (79).** Decoding @james-e-morris's real-MG puffin capture showed the strap **rejecting** our
  opcode 79 (`COMMAND_RESPONSE result=0x03`, while every accepted command — toggle-HR `0x03`,
  historical `0x16`/`0x17` — returns `0x01`), and a working third-party 5.0 app fires the buzz with
  opcode **`0x13` (19)** (`PENDING → HAPTICS_FIRED → SUCCESS`, `VALID_PATTERN`). The `send()` puffin
  branch now overrides **only the opcode** for `runHapticsPattern` on `.whoop5` (`0x13`); the payload
  is still the 4.0 preset `[patternId, loops, …]` pending the exact 5/MG payload (incoming via the
  working app's binary). Scoped strictly to the 5/MG path — **WHOOP 4.0 buzz is byte-for-byte
  unchanged** (still 79 via its own frame). The strap log now annotates the write `(puffin cmd=0x13)`.
- This may or may not buzz yet (payload unconfirmed); the immediate goal is to confirm the strap now
  **accepts** the command (result `0x01` / a haptics-fired event) instead of rejecting it. 5/MG owners:
  please share a strap log on #48.

## 1.33 — Smart alarm time actually reaches the strap

- **Fixed: the Smart-alarm wake time you set didn't always transmit to the strap** (issue #59). The
  strap's firmware alarm is set over BLE, and the send is gated on bond — but `applySmartAlarm()` was
  only called from the enable/time-change setters (`setSmartAlarm…` / `AutomationsView.onChange`),
  **never on (re)connect**. So a time changed while the strap wasn't bonded was silently dropped, and
  the strap kept its previous time (set 07:15 → still fired at the old 07:00). Both platforms had this
  gap.
- **Fix:** re-arm on the bond `false→true` transition. macOS adds a `live.$bonded.removeDuplicates()`
  sink in `AppModel.init`; Android tracks the bonded transition in `AppViewModel`'s `ble.state`
  collector. Both gated on `smartAlarmEnabled` so a disabled alarm doesn't disarm on every reconnect.
  Net effect: every time the strap reconnects, the current wake time is re-sent — so the time you set
  is the time that fires. (Re-arming on each reconnect also refreshes the next-occurrence epoch.)
- WHOOP 5/MG note unchanged: `armStrapAlarm` is still dropped by `send()` on 5/MG (its command set
  isn't verified) — this fix is for the WHOOP 4.0 firmware alarm, same as before.

## 1.32 — Today trends stay within their window (Mac)

- **Fixed (Mac): Today metric sparklines could draw all-history data under a "14-day trend" label**
  (PR #49, by rr-allin). `sparkValues` fell back to the entire series when the trailing window had
  <2 points, so a stale import rendered months-old points as a current trend. It now returns only
  `trailingWindow(all, days:).map(\.value)` — strictly within the window. A consequence (intended):
  `latestString` reads `.last` of this windowed series, so a metric whose latest reading predates the
  window shows "—" instead of a stale value — same anti-stale spirit as the #23 trailing-window fix,
  and weight's generous 90-day window keeps genuinely-recent-but-sparse readings rendering. The
  `Sparkline` view already handles 0/1 points (empty / single head dot), so no fallback is needed.
- Android: **already correct** — `remember14` strictly filters to the trailing calendar window with no
  all-history fallback (handled in the #23 era), so this is a Mac-only fix + lockstep version bump.

## 1.31 — No HR spike on resume

- **Fixed: heart rate briefly showed a stale ~100 bpm when you reopened the app / returned to Live,
  then drifted down** (issue #46). The hero number is the **median of a short smoothing window**
  (macOS `AppModel.hrWindow`, a 10s/40-sample buffer; Android `AppViewModel.hrWindow`, a 5-sample
  deque). The window was only ever cleared on explicit disconnect — never on resume or BLE re-attach.
  Since the strap only notifies every ~30s, on reopen the window still held the pre-gap samples (from
  when the user's real HR was higher) and republished that stale median until fresh low samples
  refilled it. The strap itself was never wrong (the #46 log never exceeds 75 bpm — the spike was
  entirely in the display layer).
- **Fix:** added a `resetSmoothing()` (clears the window, blanks `bpm` → `—`) and call it from the
  resume hook on each platform — `AppModel.startRealtimeHR()` / `AppViewModel.requestRealtimeHr()`.
  These fire on Live/Health screen entry, **not** on the 30s keep-alive re-arm (which goes straight to
  `ble.startRealtime()`), so steady-state smoothing is untouched; the hero shows `—` only for the brief
  moment until the first fresh reading lands, then shows the truthful value. Mirrors the existing
  `disconnect()` clear. Verified every `bpm` reader is nil-safe (zone coaching, breathe, menu bar).
- Both platforms get the real fix (the bug was present on each; only the recovery time differed).

## 1.30 — Workouts: correct source pill for Health Connect (Android)

- **Fixed (Android): Health Connect workouts showed an "Apple" pill in the Workouts list's Src
  column** (issue #53, follow-up — the Today page was fixed in 1.28). The `SessionRow` badge was a
  binary `isWhoop ? "Whoop" : "Apple"`, so every non-WHOOP session (including `health-connect`) fell
  through to "Apple". It now classifies on the row's stored origin — `deviceId`/`source` of
  `my-whoop` → "Whoop" (accent), `apple-health`/"Apple Health" → "Apple" (cyan),
  `health-connect` → **"HC"** (purple, matching the Data Sources / Today tint). "HC" is abbreviated
  to fit the narrow column, exactly as "Apple" stands in for "Apple Health" there. The classification
  is a pure `workoutSourceLabel()` helper with a unit test pinning all three importer origins.
- macOS: lockstep version bump only — Health Connect is Android-only, so macOS workouts are only ever
  WHOOP or Apple and the existing badge is already correct there.

## 1.29 — Re-scan actually scans on Android

- **Fixed (Android): Re-scan / Connect could silently do nothing on Android 12+** (issue #1; community
  PRs #54/#55). A BLE scan needs the runtime `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` (Nearby devices)
  permission; the Settings **Re-scan** button called `vm.connect()` directly, so if the permission was
  denied or revoked the scan threw `SecurityException`, the BLE layer swallowed it into a status note,
  and no prompt was ever raised — the button did nothing (the Pixel 9 report). Live's Connect and the
  onboarding flow already gated correctly; Settings was the overlooked path. The permission gate is now
  a single shared Compose helper, `rememberRequestScan {}` (`ui/BlePermissions.kt`), used by both Live
  and Settings, so no entry point can forget it. The gate must stay in the Compose layer — the
  ViewModel can't raise an Activity-scoped prompt.
- **Feedback while searching.** Settings now shows a "Searching…" status detail and disables Re-scan
  while a scan is in flight (`enabled = !live.scanning`); Live's Connect shows "Searching…" and disables
  too. The `scanning`/`statusNote` state already existed and was fully wired in `WhoopBleClient` (set on
  scan start, cleared on every terminal path — timeout, found, connected, disconnect, permission error),
  so no BLE/state changes were needed; only the buttons were missing the `enabled` gate.
- **Live control buttons stay on one line** on narrow phones (`captionNumber` + `maxLines = 1`), which
  also keeps the new longer "Searching…" label from wrapping the row.
- macOS: lockstep version bump only — CoreBluetooth has no Android-style runtime-permission prompt, so
  there's no analogous fix to make (the macOS scanning-feedback parity gap is tracked separately).

## 1.28 — Health Connect: correct source label + workout types (Android)

- **Fixed (Android): Health Connect data showed under the "Apple Health" pill on Today** (issue #53,
  follow-up to #34). The Today provenance footer unioned `apple-health` + `health-connect` into one
  "Apple Health" row. It now keeps them separate — a dedicated **Health Connect** row (its own counts +
  tint) alongside Apple Health — matching the Data Sources screen. `TodayFooterState` gained
  `hcDays`/`hcWorkouts`; the construction splits the two sources; the recent-workouts feed still unions all.

- **Fixed (Android): Health Connect workout types were mislabelled** (issue #53) — e.g. a **walking**
  session showed as **swimming**. The `EXERCISE_TYPE_NAMES` map had **wrong hardcoded integers**: `79`
  was mapped to "Swimming" but `79` is actually `WALKING`; `80` ("Swimming") is `WATER_POLO`; `82`
  ("Walking") is `WHEELCHAIR`; and yoga/HIIT/boxing/hiking/weightlifting were wrong too. The map now
  references `ExerciseSessionRecord.EXERCISE_TYPE_*` **constants** directly, so the int↔label mapping is
  resolved by the library and a renamed/removed constant is a compile error rather than a silent
  mismatch. New imports are correct immediately; **re-import Health Connect data to relabel** sessions
  imported before this fix (the sport name is stored at import time).

## 1.27 — Wrist alerts work on Android

- **Fixed (Android): wrist alerts couldn't be enabled — NOOP didn't appear in Notification Access**
  (issue #52). The Notifications screen had the full wrist-alerts UI (master toggle, per-app filters,
  quiet hours — all already persisted in `NotifPrefs`) and an "Open Notification Access" button, but the
  manifest declared **no `NotificationListenerService`**, so NOOP could never appear in the system's
  Notification Access list (and nothing acted on notifications even if it could). Added
  `com.noop.notif.NoopNotificationListener` + its manifest `<service>` (guarded by
  `BIND_NOTIFICATION_LISTENER_SERVICE`). Once the user grants access and enables wrist alerts, it buzzes
  the strap via the existing `RUN_HAPTICS_PATTERN` path on a posted notification, gated by the persisted
  settings (master, per-app opt-in, the app's buzz pattern → loops, quiet hours with midnight-wrap,
  only-when-worn) and skipping ongoing / foreground-service / group-summary noise. **Privacy-preserving by
  design: it reads only the posting package name — never notification content — and nothing leaves the
  device** (documented in `PRIVACY_SECURITY.md` §2.5). Works on WHOOP 4.0; 5/MG haptics are dropped by the
  `send()` guard until verified (#48).

## 1.26 — Smart alarm actually works on Android

- **Fixed (Android): the Automations "Smart alarm" was a non-functional mock-up** (issue #51). The whole
  screen's toggles were ephemeral `remember { mutableStateOf(false) }` with no persistence and no backend,
  and the wake time was hardcoded static `Text("07:00")` (not tappable) — so the toggle reset on navigation
  and the time couldn't be changed. The smart alarm is now a **real, persisted feature** mirroring macOS:
  `NoopPrefs` stores `smartAlarmEnabled` + `smartAlarmMinutes`; the time uses the reusable `TimeChip`
  picker (now `internal`, shared with the quiet-hours chip); and `AppViewModel.applySmartAlarm()` arms the
  strap's **firmware alarm** via `WhoopBleClient.armStrapAlarm()` (`SET_CLOCK` → `SET_ALARM_TIME(66)` with
  `[0x01]+u32 LE epoch+[0,0]`) / `disableStrapAlarm()` (`DISABLE_ALARM(69)`) — so on **WHOOP 4.0** it buzzes
  at the wake time even if the phone is asleep or NOOP is closed. Needs the strap connected to arm. (On
  5.0/MG the alarm command is dropped by the `send()` guard, same as the buzz, until verified.) The other
  Automations toggles (zone coaching / stress nudge / auto-lock) remain preview-only — a separate follow-up.

## 1.25 — WHOOP 5/MG history offload (experimental) + pairing clarity (Mac)

- **Added (macOS, experimental): a bonded WHOOP 5/MG strap now runs the historical offload.** Four
  interlocking gaps blocked it; all are now fixed, scoped strictly to `.whoop5` (WHOOP 4.0 byte-for-byte
  unchanged): (1) `connectHandshakeDone` is set after the 5/MG bond + notify-subscribe, behind a new
  `whoop5SessionStarted` once-guard that mirrors the WHOOP4 ack-storm guard (so the per-chunk acks
  re-entering `didWriteValueFor` can't re-trigger the offload mid-stream); (2) the whoop5 branch now
  kicks `requestSync(.connect)` + `startBackfillTimer()` (the trigger lived only in the WHOOP4 block);
  (3) `send()` allowlists `SEND_HISTORICAL_DATA` + `HISTORICAL_DATA_RESULT` for 5/MG (puffin-framed,
  same transport as the proven HR toggle); (4) `isOffloadFrame` is family-aware (reads the type byte at
  `frame[8]` for puffin, not `frame[4]`) and inbound puffin offload frames (47/48/49/50) route to the
  Backfiller during a backfill, while live REALTIME_DATA still only reaches the live router; the
  `Backfiller` is family-aware (parse + `end_data` slice `frame[21:29]` for 5/MG, family captured at
  `begin()`). The chunk-ack needs no new code — `send()` already owns the puffin framing + seq. **Brand
  new, needs on-hardware verification; observable stage-by-stage in the strap log.** 117 WhoopProtocol
  tests green; macOS builds clean.

- **Changed (macOS): clearer WHOOP 5/MG pairing.** The bond-refused hint ("free the strap from the WHOOP
  app — pairing mode") now shows on the **Live** screen where people connect (it was Settings-only), and
  the README has a prominent *"Pairing a WHOOP 5.0 / MG — read this first"* guide (the one-bond-at-a-time
  constraint, the `Encryption is insufficient` symptom, and the close-app → pairing-mode → connect steps).

## 1.24 — Switch between a WHOOP 4 and a 5.0/MG (Mac + Android)

- **Fixed (macOS + Android): you couldn't switch straps once one was bonded.** The Live screen's strap
  picker was gated on `!bonded` — but `bonded` is **sticky** (it survives a disconnect, meaning "this
  strap is paired"), so after the first successful pairing the picker disappeared for good. A user with
  both a WHOOP 4 and a 5.0/MG was then stuck: the scan kept targeting the first strap's service
  (`61080001` vs `fd4b0001`), so the other strap was never discovered. The picker now shows whenever
  you're **not actively streaming** (`!(connected && bonded)`), and changing the selection calls a new
  `prepareForModelSwitch()` (`BLEManager`/`WhoopBleClient`) that drops the current strap and clears the
  sticky `connected`/`bonded` state, so the newly-picked model bonds fresh. Pick the strap → Scan &
  Connect. macOS builds clean; full Android unit suite green.

## 1.23 — WHOOP 5.0/MG historical decode parity (Android)

- **Added (Android): WHOOP 5.0/MG type-47 v18 historical records now decode on Android** — bringing it to
  parity with the macOS decode shipped in 1.21. New `decodeWhoop5Historical` in `HistoricalStreams.kt`
  reads the WHOOP5-absolute layout (record @8, so `unix@15`/`hr@22`/`rr@24+`/`gravity@45/49/53` — NOT the
  WHOOP4 V24 offsets) plus the per-second fields each gated to a physical range: `skin_temp_raw@73`
  (kept only when /100 ∈ 20–45 °C), `dynamic_acceleration@41` (f32, 0–8 g), `step_motion_counter@57`,
  `motion_wear_quality@63` (0/1/2). `decodeHistorical` routes the WHOOP5 family to it; the offload
  `extractHistoricalStreams` type-dispatch is now family-aware (`frame[8]` for WHOOP5 vs `frame[4]` for
  WHOOP4). Verified by a new `Whoop5HistoricalDecodeTest` against the **same real worn/off-wrist frames**
  the macOS tests use (so both platforms decode identical bytes); full Android unit suite green, macOS
  unaffected (117 tests). Decode layer only — it activates when the 5/MG history offload runs. Fields the
  source report listed but that didn't decode consistently on this firmware (cardiac/sleep-state/perfusion)
  are deliberately omitted; SpO₂ remains impossible offline.

## 1.22 — Battery refresh on WHOOP 5.0/MG (Mac + Android)

- **Fixed (macOS + Android): "Refresh battery" was a no-op on WHOOP 5.0/MG.** `getBattery()` sent the
  WHOOP 4 proprietary `GET_BATTERY_LEVEL` command, which the `send()` guard **drops** for 5/MG (only the
  HR toggle + buzz are puffin-framed) — so a 5/MG strap's battery only updated via passive `0x2A19`
  notifications, never on demand. Both platforms now read the **standard Battery Level characteristic
  (`0x2A19`)** directly: macOS `BLEManager.refreshBattery()` (`readValue` → existing `didUpdateValueFor`
  parse), Android `WhoopBleClient.refreshBattery()` (`readCharacteristic` → a newly-added
  `onCharacteristicRead` callback → `onInbound` → `setBattery`). The char is also read once at discovery
  when readable, so a value appears as soon as you connect. WHOOP 4 keeps its legacy command path too
  (it gets both). Contributed via #47 (macOS); Android mirrored.

## 1.21 — WHOOP 5.0 historical biometrics + PPG channel fix (Mac)

- **Added (macOS): WHOOP 5.0 type-47 v18 records now decode more biometric fields**, each gated to a
  physically-real range and cross-validated against real worn-vs-off-wrist frames (the data is the
  arbiter): **skin temperature@73** (u16/100 °C — ~30.6 °C worn, ~22.5 °C off-wrist, AS6221 thermistor;
  the raw sensor, not WHOOP's cloud-calibrated summary), **dynamic acceleration@41** (f32 g, gated 0–8),
  a **cumulative motion/step counter@57**, and **wrist-contact/motion quality@63** (enum 0/1/2). Fields
  the source report listed but that did **not** decode consistently on this device's firmware
  (cardiac_flags@33, sleep-state@81, perfusion@69/71) are deliberately left in the raw region pending
  more captures — so NOOP never ships a guessed offset. These are building blocks toward on-device 5.0
  sleep/recovery (decode layer only; not yet surfaced in the UI).

- **Fixed (macOS): the WHOOP 5.0 v26 PPG channel index was read from the wrong byte.** A community
  reverse-engineering report (validated against a 22 h overnight corpus) and NOOP's own two real test
  fixtures both show the channel is **`frame[21]` (values 1–26, a time-multiplexed sweep)**, not
  `frame[12]` — the `0x41`/`0x46` that the merged v1.19 decode reported were a high-entropy counter byte
  caught during a short 2-burst capture. Corrected and gated to 1…26 so a wrong offset stores nothing.
  The PPG **waveform** decode (LE i16 @[27:75]) was always correct and is unchanged. This 26-way
  time-multiplex is also why **SpO₂ is not recoverable offline** (it needs simultaneous red+IR; no two
  channels are ever co-sampled). 117 WhoopProtocol tests green.

## 1.20 — Strap log stays off the system log (Android)

- **Changed (Android): the strap connection log is no longer mirrored to logcat by default** (PR #45).
  It was always written to Android's system log via `Log.d` — even in release builds — so a normal user
  emitted the device's BLE control flow to the device-wide log with no way to turn it off. It's now
  **opt-in**: a new **Settings → Strap → "Debug logging"** toggle (default **off**, persisted as
  `NoopPrefs.KEY_DEBUG_LOGGING`) gates the single `Log.d` call, applied to the process-wide BLE client at
  the composition root so the low-level client never depends on the UI/prefs layer. The in-app ring
  buffer still records unconditionally, so **"Share strap log" keeps working for everyone** (the bug-report
  path from #17/#18) — only the adb-visible mirror is gated. Developers flip it on to watch a session over
  `adb logcat -s WhoopBleClient`. No BLE flow, protocol, or storage change; WHOOP 4.0 and 5/MG unaffected.
  Documented in `PRIVACY_SECURITY.md` §2.4 (what the log does/doesn't contain) and `ANDROID.md`.

## 1.19 — Import polish (Mac) + WHOOP 5 optical decode

- **Changed (macOS): import buttons lock while an import runs** (follow-up to #40). While either
  source is writing to the store, both Data Sources buttons disable and only the active source shows a
  spinner — preventing two concurrent imports and keeping the loading state on the correct card. Each
  source already kept its own status line (from 1.18); this serialises the import itself behind a single
  `activeImportSource`.

- **Added: WHOOP 5.0 optical PPG waveform decoded** (#43). The strap's high-rate type-47 **version-26**
  history record — previously a raw region — is now decoded as a **24 Hz optical photoplethysmography
  (PPG) trace**: 24 little-endian i16 ADC samples per second (`unix` u32 LE @15, channel id @12). It was
  identified as optical, not motion, using heart rate as *internal* ground truth — the concatenated
  waveform autocorrelates to the measured HR (lag 14 ≈ 103 bpm vs 101.7 bpm), trough-detection gives a
  ~563 ms inter-beat interval, and the pulse stays HR-locked even when the wrist is still. Raw ADC counts
  are exposed verbatim as `ppg_waveform` (PPG has no absolute unit — no scale is invented). Visible in
  the strap inspector / `whoop-decode`; a building block toward 5.0 recovery and strain. Decoder-only and
  version-keyed, so v18 and unknown versions are unaffected.

## 1.18 — Import fixes (Mac + Android)

- **Fixed (macOS): an Apple Health import overwrote the WHOOP import's status message** in Data Sources
  (issue #40). The two importers shared one `importing`/`importSummary` state, and only the WHOOP card
  rendered the summary — so importing Apple Health flipped both buttons to loading and replaced the WHOOP
  message in the WHOOP section, looking like a data overwrite. The data was always stored under separate
  sources (`my-whoop` vs `apple-health`); split the UI state per source (`whoopImporting`/`appleImporting`
  + per-source summaries) and gave the Apple Health card its own status line.
- **Fixed (Android): one failing Health Connect record type aborted the whole import** (issue #34). All
  the `readAll` calls ran inside a single try/catch, so a device/SDK quirk on any one type (e.g. the
  "count must not be less than 1, currently 0" some Health Connect builds throw) failed the entire
  import. Each type's read is now self-contained — on failure it's logged and skipped, and every other
  type still imports (reads accumulate into shared buckets, so a partial type is simply absent, never
  corrupt).

---

## 1.17 — Sleep from WHOOP 4 on unmapped firmware (Mac)

- **Fixed (macOS): a WHOOP 4 on firmware whose historical record version NOOP hadn't mapped recorded no
  sleep.** Root cause: sleep is staged from the strap's overnight **gravity/motion** stream
  (`SleepStager.detectSleep` requires gravity — empty gravity → 0 sleeps). The WHOOP 4 historical
  (type-47) post-hook **bailed out entirely on any version outside the schema's `{12, 24}`** —
  `guard resolveVersion(...) else { region("unmapped"); return }` decoded nothing (no HR, no R-R, **no
  gravity**). So the offload "completed" (acks + HISTORY_COMPLETE) yet stored no motion, HR got
  backfilled from the realtime stream (which carries none), and `IntelligenceEngine` produced a day with
  HR but zero sleeps. **Fix:** for an unmapped version, fall back to the canonical **v24 DSP layout**
  (firmware overwhelmingly shares it — the schema notes V12 == V24) and accept it **only if it decodes
  to physically-real data** — `|gravity| ≈ 1 g` (the DSP gravity is a unit vector) and a plausible HR. A
  wrong layout yields random f32 gravity nowhere near 1 g, so it's rejected and the record left raw (the
  Backfiller then logs the unmapped version once to the strap log, so we can map it). Mapped versions are
  unchanged. New tests cover accept + reject. Issue #30. *(Android has its own decoder; this is the Mac
  fix for the reporters' platform.)*

---

## 1.16 — Health Connect shows as Health Connect (Android)

- **Fixed (Android): Health Connect data was attributed to "Apple Health."** `HealthConnectImporter`
  stored its daily aggregates (steps/HR/HRV/sleep/weight) under the shared `apple-health` deviceId — the
  same bucket the Apple Health export uses — so the Data Sources screen counted them under the Apple
  Health card (only the workouts were correctly tagged `health-connect`). It now files **all** Health
  Connect data under its own `health-connect` source, named "Health Connect," and the Data Sources
  Health Connect card shows its own counts. The unified-external-health read sites (Today footer,
  Workouts) union both sources, so nothing disappears; `CompareScreen` is unaffected (Health Connect
  writes no `metricSeries`). A one-time refile runs at the start of a Health Connect import to move any
  legacy `apple-health` Health-Connect data across (safe + idempotent: HC writes no `metricSeries`, so
  `apple-health` daily rows with no `metricSeries` are unambiguously HC-origin; runs before the import so
  re-importing never duplicates). No data was ever lost — labelling only (issue #34).

---

## 1.15 — WHOOP 5/MG: the wrist buzz works

- **The haptic buzz now fires on WHOOP 5.0/MG (experimental), both platforms.** @jamartif confirming live
  HR on v1.13 proved a 5/MG strap acts on NOOP's puffin-framed commands — so the buzz
  (`RUN_HAPTICS_PATTERN`) is now allowlisted through the same `puffinCommandFrame` transport that the
  realtime-HR toggle uses, in `send()` on both `BLEManager.swift` and `WhoopBleClient.kt`. That powers
  Test buzz, the smart alarm, and any haptic feedback on 5/MG. Still experimental — whether the strap
  honours that specific command is the unverified part, but the transport is proven and the worst case is
  a no-op (no link teardown observed with the HR toggle). All other commands stay dropped for 5/MG (the
  offload set needs its own verified framing). Battery already worked on 5/MG via the standard `0x2A19`
  profile, so it needed nothing here. WHOOP 4.0 is unaffected (issue #28).

---

## 1.14 — Android Today: clearer empty states for stale imports

- **Android Today now renders missing current-day metrics as explicit "No Data" instead of raw dashes**,
  and the recovery ring no longer shows a `0% / depleted` state when there's simply no recovery row for
  today — so after a historical import, Today reads as "no score for today yet," not a broken-looking zero.
  Added a Mac-style Today footer for provenance: recent 14-day workouts (when present) plus Data Sources
  counts, so imported history is clearly labelled as history. No change for a user who has today's data —
  values render normally; only genuinely-absent values show "No Data." Brings Android to parity with the
  Mac Today screen and completes the stale-import work from v1.11/v1.12. Android-only (TodayScreen,
  TrendsScreen comment); reimplemented as NOOP from @Brechard's PR #31 (refs #23).

---

## 1.13 — WHOOP 5/MG heart rate on Android

- **Fixed (Android, WHOOP 5/MG): bonded but no heart rate.** Android brought the strap to "Bonded —
  Streaming" (v1.10) but then listened for HR only on the standard `0x2A37` profile — which a 5/MG
  strap doesn't stream. Realtime HR rides the puffin notify chars (`fd4b0003/4/5/7`) as `REALTIME_DATA`,
  exactly as on macOS. NOOP now, on the `.whoop5` path only: (1) subscribes those puffin notify chars
  **after** the `CLIENT_HELLO` bond (they're rejected on an unauthenticated link); (2) makes the frame
  reassembler **family-aware** (5/MG framing is `declLen @[2..4]` / total `+8`, vs WHOOP4 `length @[1..3]`
  / `+4` — the WHOOP4 rule decoded a bogus ~6 KB length and never emitted a frame); (3) decodes `REALTIME_DATA`
  at the WHOOP5 `+4` offsets (HR @16) — the same hardware-verified decode shipped for macOS in PR #21; and
  (4) sends the realtime-HR toggle with **puffin command framing** (`send()` dropped every 5/MG command
  before). Verified by unit tests against a real worn-strap frame (HR=98, R-R=[603,587]); the new decode +
  reassembler are covered. Still experimental on 5/MG; WHOOP 4.0 is byte-for-byte unaffected (issue #17/#26).
- **Note:** other 5/MG commands (battery poll, haptic buzz) still need their own verified puffin framing
  and remain dropped for now — only the realtime-HR toggle is wired, because it's the one confirmed on
  hardware. So buzz on a 5/MG strap isn't expected to fire yet (issue #28).

---

## 1.12 — WHOOP 5/MG heart rate on Mac + Readiness anchoring

- **Fixed (macOS, WHOOP 5/MG): the connect bonding and actually streaming live HR.** The v1.5 attempt
  bonded but still failed on real 5/MG hardware because it subscribed the protected puffin notify chars
  (`fd4b0003/4/5/7`) at *discovery*, before the link was encrypted — the strap rejected them with
  *"Authentication is insufficient"* and the bond write itself failed *"Encryption is insufficient."*
  NOOP now (1) retains those chars but defers the subscribe until the `CLIENT_HELLO` `.withResponse`
  write confirms in `didWriteValueFor`; (2) arms realtime HR post-bond with **puffin command framing**
  (`puffinCommandFrame(TOGGLE_REALTIME_HR)`) — the `send()` guard previously dropped every 5/MG command,
  so even a bonded strap never started streaming; and (3) surfaces actionable pairing-mode guidance when
  the bond is refused (`Encryption/Authentication is insufficient`) — CoreBluetooth won't start a fresh
  just-works bond against a strap still bonded to the official WHOOP app, so it must be in pairing mode
  (blue LEDs, WHOOP app closed). Reimplemented from a 5/MG owner's hardware-verified flow (issue #17).
  WHOOP 4.0 is untouched; the change is scoped entirely to the `.whoop5` path.
- **Fixed (Mac + Android): the Readiness card still anchoring to the newest stored row.** v1.11 anchored
  Today, the sparklines and the Trends windows to the device's real calendar day, but left
  `ReadinessEngine` reading `sorted.last`, so the "Should you push today?" card still synthesised off a
  stale import's newest day. Both platforms now pass the local day key into `evaluate(...)`, and the
  engine treats an explicit-but-absent `today` as *insufficient* rather than falling back to the newest
  row — so on a stale import the readiness card hides instead of showing an old day's read. No-op for
  anyone wearing the strap nightly (today's row exists). Caught via @Brechard's PR #24 (issue #23/#24).

---

## 1.11 — Today reflects today, not stale imports

- **Fixed (Mac + Android): the dashboard treated the newest *imported* day as "today."** After a
  historical WHOOP import, the Today hero, the 14-day sparklines and the Trends W/M/3M windows were all
  anchored to the newest stored *row* (or `latestDay`) rather than the device's actual calendar date —
  so a months-old import showed as today's recovery/readiness, and the trend windows showed the last N
  imported days instead of the last N calendar days. Today now resolves by the real local day key
  (`yyyy-MM-dd`), and the sparkline/Trends windows are date-anchored to today; older imports stay
  visible under the wider ranges / All history. No change for the common case (recent contiguous data:
  last-N-days == last-N-rows) — only stale-import dashboards are corrected (issue #23).

---

## 1.10 — WHOOP 5/MG bonding on Android + Health Monitor fix

- **Fixed (Android, WHOOP 5/MG): the strap connecting but never bonding.** It wrote `CLIENT_HELLO`
  unacknowledged (`WRITE_TYPE_NO_RESPONSE`), which never triggered the just-works bond the `fd4b` strap
  needs — so it sat connected, unbonded, and silent (the strap won't even stream the standard `0x2A37`
  HR on an unauthenticated link). `CLIENT_HELLO` is now a confirmed write that triggers bonding (the
  same fix shipped for macOS in v1.5), so live HR can come through. Experimental; isolated to the 5/MG
  path — WHOOP 4.0 unaffected (issue #17).
- **Fixed (Health Monitor): the heart-rate chart freezing when opened from the Live page.** Leaving
  Live sent `TOGGLE_REALTIME_HR=0`, switching the stream off, so Health Monitor (which also shows live
  HR) got nothing. The realtime stream is now ref-counted and stays on while any live-HR screen is
  visible (issue #18).

---

## 1.9 — Fix: bonded but no live data (Android)

- **Fixed (Android): a strap that connects and bonds but shows no live data** — heart rate, battery,
  worn and events all blank (it reproduces reliably on newer Android). A GATT callback-threading race
  let the bond's with-response write fire before the notification subscriptions and starve them as
  BUSY, so the strap looked bonded (commands like buzz worked) but not one notification was ever
  enabled. NOOP now pins all GATT callbacks to the main looper (API 28+) and retries a transiently-BUSY
  subscribe. Reported, diagnosed and hardware-verified (Pixel 8 / Android 16) by a community
  contributor (PR #22); reviewed for no regression to the verified WHOOP 4.0 path.

---

## 1.8 — Strap-log export on Mac + a Health Monitor fix

- **New (Mac): export the strap log.** The Live screen's strap-log card now has **Copy** and **Save…**
  buttons, so Mac users can attach the connection log to a bug report — Android has had this since 1.6,
  Mac didn't (issue #17).
- **Fixed: Health Monitor heart-rate chart flat-lining.** It derived the chart from R-R intervals,
  which are sparse on WHOOP 4.0, so it sat on a flat 2-point line even while HR was clearly changing.
  It now plots a rolling buffer of your live heart rate over time (issue #18).

---

## 1.7 — WHOOP 5/MG frame capture + protocol workbench

- **New (Mac): opt-in WHOOP 5/MG frame capture.** Settings → Experimental → "Record puffin frames"
  logs the strap's raw 5/MG ("puffin") frames — each stamped with a timestamp and your live heart
  rate as ground-truth — to a JSON file, with Export / Reveal actions. Read-only on the strap, off by
  default, and never touches WHOOP 4.0. This is how 5/MG owners can contribute the captures needed to
  decode recovery / strain / sleep.
- **Dev tooling:** a headless Linux capture workbench (`tools/linux-capture/`, Python + bleak) and a
  `whoop-decode` CLI that decodes captures with the same `WhoopProtocol` decoder the apps ship — no
  second decoder to drift. Plus hardware-verified WHOOP 5.0 bonding/session notes in
  `docs/BLE_REVERSE_ENGINEERING.md` that confirm the v1.5 just-works-bond approach.
- Cherry-picked from community PRs #19 and #20 by @j0b-dev — reviewed, build-verified, and
  reimplemented for the repo.

---

## 1.6 — Share strap logs, and a worn-status fix

- **New (Android): Share strap log.** Settings → Strap → **"Share strap log"** writes the connection
  log to a file and opens the share sheet, so you can attach it to a bug report. Android's logs
  weren't reachable without `adb`, which is why connection problems on Android (issues #17, #18) were
  hard to diagnose — now they're one tap away.
- **Fixed (Android): the "Worn" status always reading Off.** The Android default was wrong (`false`);
  it now defaults to worn until the strap reports otherwise, matching the macOS app (issue #18).
- **Mac:** the alarm debug log now prints your **local** wake time instead of UTC. Alarms already
  fired at the correct local time — the log's "+0000" was just `Date`'s default UTC formatting.

---

## 1.5 — WHOOP 5/MG: secure-pairing fix

- **Fixed (experimental): WHOOP 5.0/MG stuck at "Finishing the secure pairing handshake."** The 5/MG
  strap requires an encrypted (bonded) Bluetooth link before it will let the app subscribe to its
  characteristics — it was rejecting them with "Authentication is insufficient," so the handshake
  waited forever and live heart rate never arrived. NOOP now writes the `CLIENT_HELLO` with-response
  to trigger just-works bonding, then subscribes once the link is authenticated. Diagnosed from a
  shared strap log by a contributor on issue #17. **Still experimental on 5/MG** — if you have one,
  please try it and share your strap log so we can keep improving it. WHOOP 4.0 is unaffected.

---

## 1.4 — Live heart rate that doesn't freeze

- **Fixed: live heart rate freezing mid-session.** The WHOOP firmware lets its realtime stream lapse
  if it isn't periodically re-armed, which left heart rate stuck on a stale number while the strap was
  still "connected" — the only fix was a manual disconnect/reconnect. NOOP now runs a 30-second
  keep-alive that re-arms the realtime stream, re-subscribes a dropped notification, and — if nothing
  has arrived for two minutes — reconnects on its own. This ports the macOS app's existing keep-alive
  to Android, so the two platforms behave the same.
- **Fixed: a corrupt Bluetooth packet could wedge the live stream.** The frame reader now rejects an
  impossible frame length and resyncs to the next packet, and starts each connection from a clean
  buffer, so a single bad packet can't freeze the stream until you reconnect.

---

## 1.3 — Stays connected in the background

- **New: keeps your strap connected when the app is closed.** On Android, NOOP runs a quiet ongoing
  foreground-service notification that holds the Bluetooth link open, so your heart rate keeps
  streaming and offloads keep landing even after you swipe the app away. On macOS this already came
  for free — close the window and NOOP keeps running from the menu bar.
- **New: "Keep connected in the background" toggle** in Settings → Strap, on by default. Turn it off
  and NOOP disconnects whenever you close the app (and drops the notification with it).
- **Fixed:** the strap dropping the instant you closed the app (the connection used to be torn down
  with the screen). The BLE client is now owned by the app process, not the UI.
- **Fixed:** the Android notification permission is now actually declared and requested, so the
  background notification can appear on Android 13+.

---

## 1.2 — Readiness, and the start of WHOOP 5/MG

- **New: Readiness.** A "should you push today?" card on Today that synthesizes established
  sports-science signals from your own history — HRV vs your baseline (Plews/Buchheit), resting-heart-
  rate drift (Lamberts), sleeping respiratory rate, training-load balance (the acute:chronic workload
  ratio, Gabbett) and training variety (monotony, Foster) — into one headline (Primed / Balanced /
  Strained / Run down) with the drivers beneath it. Pure on-device math; not medical advice.
- **WHOOP 5/MG: live heart rate now works.** Deeper 5/MG metrics (recovery, strain, sleep) are still
  experimental and being worked on.
- **Opt-in WHOOP 5/MG protocol probes** under Settings → Experimental, for 5/MG owners who want to
  help map the protocol. Off by default; never affects WHOOP 4.0.
- **Localized exports import fully.** German (and other localized) WHOOP exports now import with real
  values, not blanks — the column headers are mapped, not just the filenames.
- **Fixes.** The WHOOP 5/MG "stuck connecting" state, and the macOS "Choose export" button.

## 1.1 — Scores live from the strap

- **On-device scoring.** Recovery, strain and sleep now compute live from the strap, not only from an
  import. They calibrate over your first few nights, like any recovery wearable.
- **Pick your strap** (WHOOP 4.0 or 5.0/MG) before connecting, so it looks for the right one.
- **Universal macOS build** that runs on both Intel and Apple Silicon.

## 1.0 — First release

- Pair directly with a WHOOP strap over Bluetooth — no WHOOP account, no cloud.
- Compute recovery, strain, HRV and sleep locally on your own device.
- Bring your history: import a WHOOP export, an Apple Health export, or Android Health Connect.
