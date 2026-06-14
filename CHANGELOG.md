# Changelog

All notable changes to NOOP. NOOP is an independent, experimental project — not the WHOOP app, and
not affiliated with WHOOP. It reads a strap you own, on your own device, fully offline. Dates are
approximate; downloads are on the [Releases](https://github.com/NoopApp/noop/releases) page.

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
  strap log on [#174](https://github.com/NoopApp/noop/issues/174) is exactly what we need to finish 5.0/MG
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
  span ("Fri 13 → Sat 14 Jun"). Implemented from [PR #173](https://github.com/NoopApp/noop/pull/173) —
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
