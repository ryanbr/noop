import Foundation

/// Single source of truth for the in-app "What's New" screen and the expectation-setting copy used
/// in onboarding. Mirrored byte-for-byte by the Android `AppChangelog.kt` and the repo CHANGELOG.md
/// so every surface tells the same story.
enum AppChangelog {

    /// Bump this when you add a release below. The "What's New" sheet shows automatically when the
    /// stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
    static let currentVersion = "5.0.0"

    struct Release: Identifiable {
        let version: String
        let title: String
        let date: String
        let items: [String]
        var id: String { version }
    }

    /// Newest first.
    static let releases: [Release] = [
        Release(
            version: "5.0.0",
            title: "v5 — the raw-signal release: NOOP reads the signal, on your device, free",
            date: "June 2026",
            items: [
                "**The big idea.** Everyone else shows you a score their cloud computed, behind a subscription. NOOP reads your strap's raw signals — beat-to-beat timing, red/IR PPG, motion, skin temperature — and does all the maths on your own device, free and offline. And it's the only one that can actually breathe you back down. Seven new things below, plus a tidier home: everything now lives under five places — **Today · What Moves You · Health · Devices & Sources · Settings**.",
                "**Haptic biofeedback — the strap that breathes you down.** Your wrist motor can now pace your breathing with the screen off. Find your personal calm pace (open **Breathe → Resonance → Find your resonance pace**, pick the ~13-min or ~7-min sweep), then breathe to the buzz. Mid-stress, tap **Calm me · 3 min** for a felt metronome just below your heart rate. Optional passive check-ins: **Settings → Automations → Stress check-ins (haptic)** (off by default).",
                "**What Moves You.** A ranked, lag-aware read of what actually moves *your* recovery — from your own journal and outcomes, not population averages. Log alcohol or late caffeine with an amount and NOOP fits a personal dose-response curve, then in the evening tells you what one more drink tends to cost tomorrow's Charge. Open **What Moves You** (the wand in the sidebar / Insights).",
                "**Skin-temperature suite.** Three features off the one signal WHOOP already streams: cycle-phase **awareness** (opt-in, on-device, never contraception or a fertility predictor), a **Body clock** jet-lag/shift helper, and a smarter illness **Heads-up** that cross-checks your journal so a night out doesn't cry wolf. Find them in **Health → Skin temperature**; turn cycle awareness on there, illness watch under **Settings → Automations**.",
                "**Your Data, Fused.** If you wear more than one band, NOOP now shows one honest record — best source wins per metric, with the source named on every number and conflicts flagged, never silently averaged. Open **Your Data, Fused** from **Health** or Data Sources. A single WHOOP just shows a clean plain record.",
                "**Lab Book — your own private logbook.** Type in your bloods, blood pressure, scan values or doctor's-visit notes (or import a CSV), see each marker's trend, and line a marker up against a wearable signal with **Compare with a signal**. It's a notebook, not a medical service — NOOP stores and lines up the numbers *you* enter, never tests, reads or diagnoses them, and it all stays on your device. Open **Health → Lab Book**.",
                "**Rhythm (experimental).** A picture of your beat-to-beat timing — a Poincaré scatter with plain descriptive stats. It's a visualisation, not a verdict: not an ECG, not a diagnosis, can't detect any heart condition. Off by default behind a consent screen: **Settings → Rhythm → Turn on Rhythm**.",
                "**A smarter, still-private AI Coach.** The opt-in bring-your-own-key Coach can now optionally reason over your on-device patterns and Lab Book markers — summaries only, nothing raw ever leaves your device. Turn it on in **Coach** with **Also share my patterns & Lab Book** (off by default; your key, your choice of provider).",
            ]),
        Release(
            version: "4.9.1",
            title: "More realistic calories + honest alarm wording",
            date: "June 2026",
            items: [
                "**More realistic daily calories.** The all-day energy estimate was running high — it credited ordinary daytime heart rate at exercise intensity. Now only genuine exertion counts at the higher rate, so your daily burn reads closer to reality. (Thanks to everyone on the subreddit who flagged it.)",
                "**Honest Smart-alarm wording.** The Smart-alarm card now says up front that a strap-driven wake is experimental and hasn't been verified to fire on WHOOP 4.0 or 5/MG — so keep a backup alarm. (No behaviour change; we just stopped over-promising.)",
                "**Smoother iPhone sideloading.** Fixed the AltStore/SideStore source so adding it no longer fails with \"given data not valid JSON\" (the old link pointed at a host that's gone).",
            ]),
        Release(
            version: "4.9.0",
            title: "Steadier heart rate + a stack of fixes",
            date: "June 2026",
            items: [
                "**Steadier live heart rate.** The Health tab and the Mac menu bar now show the same spike-filtered reading as the Live screen, so a brief sensor blip no longer flashes a wild number like 170+. (Thanks @ryanbr and @bringiton321 — #39.)",
                "**Homebrew install fixed (macOS).** `brew install` works again — the tap command now points at the project's self-hosted home; the old short form pointed at a host that no longer serves it. See the README for the one-line command. (Thanks @tonyjacked — #44.)",
            ]),
        Release(
            version: "4.8.0",
            title: "On-demand HRV, a haptic clock, sleep marks & more",
            date: "June 2026",
            items: [
                "**New: take an HRV reading on demand.** An \"HRV reading\" button on the Live screen captures about 60 seconds of your heart's beat-to-beat timing and gives you a single RMSSD reading right there — sit still, breathe normally, and watch it settle. Saved alongside the rest of your data. (#127.)",
                "**New: feel the time — Haptic Clock.** Your strap can now buzz out the current time: long buzzes for tens, short for units, hours then minutes. Set a strap double-tap to \"Buzz the time\" under Automations (on Android there's a \"Buzz the time\" button in Settings → Diagnostics). (#460.)",
                "**New: tap to mark sleep.** Two buttons on the Sleep screen — \"Going to sleep\" and \"I'm awake\" — log a timestamped mark so you keep your own record of when you turned in and woke up. (#461.)",
                "**New: scheduled debug export (Android).** Turn on a daily auto-export of your strap log at a time you choose, written with timestamped filenames — handy for attaching to a bug report without remembering to grab it. (Thanks @maddognik — #510.)",
                "**Clearer steps screen on a WHOOP 4.0.** If your strap hasn't synced any motion yet, the Steps calibration screen now explains why it's empty — it needs your strap's banked motion history to sync first. (Thanks @bringiton321 — #37.)",
            ]),
        Release(
            version: "4.7.0",
            title: "Mi Band import + a big WHOOP 4.0 sleep fix",
            date: "June 2026",
            items: [
                "**New: import a Xiaomi Mi Band.** Bring a Mi Band / Smart Band 8, 9 or 10's full history — steps, heart rate, resting HR, sleep stages, SpO₂, stress and sleep score — straight from the Mi Fitness app's on-device database. No Bluetooth, no Xiaomi account; it gets its own page with a per-night hypnogram and shows up across Explore, Compare and Correlations. (Thanks @matt — #35.)",
                "**Fixed: WHOOP 4.0 sleep tracking.** A 4.0 night rebuilt from clumped motion was being shredded at each long dropout into fragments and thrown away — so you'd get ~0 sleep or a night split in half with the wrong start. It now bridges across the dropouts (vouched by heart rate) into one correct night. (Thanks @ryanbr — #28, #33.)",
                "**Fixed: no more \"-874 kcal\".** A workout's calories were drawn with a trend arrow that read as a minus sign — plain numbers now show no arrow. (Thanks @Dumbledodge — #41.)",
                "**Fixed: Explore taps** on iPhone no longer flash the detail and bounce back. (Thanks @matt — #38.)",
                "**Cleaner Settings on a WHOOP 4.0** — the 5/MG-only experimental controls are hidden when you're on a 4.0 (your strap model is detected automatically). (#22.)",
                "**Faster overnight catch-up** after your phone's been off — a strap that drip-feeds its history now drains back-to-back instead of stalling between chunks. (#25.)",
                "**Bounded local storage** — the experimental raw-capture buffers are now size-capped. (#27.)",
                "**Apple Health body composition** — NOOP now reads your weight, body-fat %, lean mass and BMI from Apple Health on iPhone. (Thanks @h3ld3r — #20.)",
            ]),
        Release(
            version: "4.6.2",
            title: "A bolder Today screen",
            date: "June 2026",
            items: [
                "**The Today scores got a glow-up.** Charge, Effort and Rest now ride on crisp, full-circle gauges that sweep in and count up — a cleaner, bolder at-a-glance read on iPhone and Android. (Thanks to @unruffled688 for the iOS redesign — #23.)",
                "Fixed: the **Releases** links in the project README and docs pointed at a path that returned a 404 on the new home — they now go straight to the downloads page. (#26)",
            ]),
        Release(
            version: "4.6.1",
            title: "NOOP has a new home",
            date: "June 2026",
            items: [
                "**NOOP now lives at noop.fans.** After the project's GitHub was taken offline, NOOP moved to its own independent home — code, releases, the wiki and issues. **Settings → About** now links straight there, and **Check for updates** reads from the new home (if GitHub ever comes back it'll be kept as a mirror). Nothing on your device changed and everything keeps working — this just points the app at where the project lives now. Keeping it online costs real money, so if NOOP is useful to you, please consider a donation. #KeepNOOPAlive",
            ]),
        Release(
            version: "4.6.0",
            title: "Editable naps, a richer Trends report, and better debug export",
            date: "June 2026",
            items: [
                "**Naps are now editable — and stay their own thing.** You can edit a detected nap's start and end times (NOOP re-stages it from your raw data and the correction sticks through future syncs), and manually add a nap the strap missed, right from the Sleep screen. Naps are always tracked as separate sessions from your main sleep, so the awake time between them is never mislabelled as light sleep. (#508)",
                "**Trends report adds Workouts and Stress.** The exportable Trends report now leads with a **Workouts** row (your activity count over the range) and a **Stress** row (NOOP's 0–3 daily autonomic-load trend), each with its own averages and a measured-vs-computed note, alongside recovery, sleep, HRV and the rest. (#457)",
                "**Better on-device debug export** (for the tinkerers): the in-app strap log now keeps a rolling **24 hours** (up from ~1h), exported logs and raw captures get a **date-stamped filename** so shares don't overwrite each other, and a new one-tap **\"Export raw + log\"** hands over both as a matched pair. (#510, thanks j0b-dev & maddognik for pushing the protocol work.)",
            ]),
        Release(
            version: "4.5.5",
            title: "Today's Effort no longer drops to zero",
            date: "June 2026",
            items: [
                "**Fixed: the Effort number on Today could briefly show the right value, then fall to 0.** The live \"so far today\" Effort recalculation could under-read — especially on a WHOOP 5/MG with sparser heart rate, or after you'd logged a workout — and replace the real Effort you'd already earned. The gauge now never shows **less** than today's earned Effort. (#489 / #506)",
                "**The strap log is now in Settings on iPhone too** (Settings → Strap → Copy / Save), matching Mac — so it's easy to grab for a bug report without hunting on the Live screen. (#509)",
            ]),
        Release(
            version: "4.5.4",
            title: "Find your strap log in Settings (macOS)",
            date: "June 2026",
            items: [
                "Added a **Strap log** shortcut to **Settings → Strap** on Mac — Copy or Save the log right from Settings instead of hunting for it on the Live screen. It's the one thing needed to diagnose a bug, so it should be easy to reach.",
            ]),
        Release(
            version: "4.5.3",
            title: "Sleep fix for WHOOP 4.0 + accurate WHOOP 5/MG steps",
            date: "June 2026",
            items: [
                "**WHOOP 4.0: a real night is no longer dropped.** The off-wrist guard added in 4.5.0 could mistake a 4.0's sparse, motion-reconstructed sleep heart-rate for time off the wrist and skip the whole night. It now only treats heart-rate gaps as \"off-wrist\" when your heart-rate is dense enough for a gap to actually mean something — so 4.0 nights track again, while the strap-on-a-desk case it was meant to catch still works. *(Thanks Mindfulpaths for catching it — #507.)*",
                "**WHOOP 5/MG: steps are accurate now.** The strap's step counter is a *running total*, not a per-reading count — adding it up the old way could over-report steps many times over. NOOP now reads the full counter and adds only the real increases, so your daily step number is sane. It also reads a simple still / walking / running activity signal from the same data, with no cloud. *(Thanks j0b-dev for the analysis — #276 / #316.)*",
            ]),
        Release(
            version: "4.5.2",
            title: "Honest labelling for WHOOP 5/MG deep-data diagnostics",
            date: "June 2026",
            items: [
                "Corrected the experimental WHOOP 5/MG \"deep data\" diagnostics wording. It used to announce *\"Deep data is flowing — please share your strap log!\"* when it saw certain frames — but we've since confirmed those frames are just **historical-sync data** (often another app pulling the strap's backlog over Bluetooth), **not** a separate live stream that the enable sequence unlocks. The counter and logs now say exactly that, so nobody's sent chasing a live unlock that isn't there. Purely a wording change — no behaviour difference. *(Thanks to community contributor j0b-dev — #494.)*",
            ]),
        Release(
            version: "4.5.1",
            title: "Sleep: keep real nights when the strap comes off",
            date: "June 2026",
            items: [
                "A quick refinement to yesterday's off-wrist sleep fix. NOOP now only discards a sleep block when **most of it** (half or more) is off-wrist, rather than dropping it for any off-wrist gap at all. So a real night where you take the strap off shortly after waking is kept in full, while a strap left sitting still on a desk all day is still correctly ignored. *(Thanks to community contributor j0b-dev for the sharper approach.)*",
            ]),
        Release(
            version: "4.5.0",
            title: "WHOOP 5/MG deep-sync decode + sleep & workout fixes",
            date: "June 2026",
            items: [
                "**More of your WHOOP 5/MG history now syncs.** Some nights were stored by the strap in newer record layouts (internally \"v20/v21\") that NOOP didn't recognise yet, so they were skipped and showed up as empty. Those now decode — so more of your 5/MG history comes through. We also pull richer detail from the existing records (higher-precision heart rate, step cadence, an extra skin-temperature channel) and corrected the skin-temperature scale so worn readings land where they should. *(Thanks to community contributor j0b-dev for the captured-frame analysis behind this.)*",
                "**Sleep: no more daytime false sleep.** Time with the strap off your wrist — on the charger, or sat at a desk — could occasionally be logged as sleep. NOOP now spots those gaps (a long stretch with no real heart-rate signal, or an explicit off-wrist marker) and won't count them as sleep, day or night.",
                "**Sleep: fixed a 6 PM wake-time clamp.** On some past nights your wake time could be reported as exactly 6 PM — an artefact of the read window ending there, not your real wake. Past nights now read through the full day so your true wake time shows.",
                "**Workouts: Average HR always matches the trace.** A workout's Average HR is now always computed from the exact heart-rate samples behind the graph and zones, so the number and the chart can never drift apart.",
                "Fixed a build warning and repaired the macOS/iOS download links for the 4.4.0 release.",
            ]),
        Release(
            version: "4.4.0",
            title: "Classic chart colours — a throwback toggle",
            date: "June 2026",
            items: [
                "**You can now flip every gauge, ring, chart and scale to the traditional red → amber → green readiness palette** — the colourful style people know. Settings → Appearance → **Chart colours**: pick **Titanium** (the brand gold/amber/blue ramps, the default) or **Classic**. Classic re-colours the *data* — recovery goes red→green, HR zones run cool→hot, stress is green→red, sleep gets a purple REM band — while leaving the app's chrome (surfaces, text, buttons) exactly as it is. It works in **both Light and Dark**. Nothing about your numbers changes; only how they're coloured.",
            ]),
        Release(
            version: "4.3.2",
            title: "Light theme tuning",
            date: "June 2026",
            items: [
                "**Light got dialled in.** Based on early feedback it was leaning too gold, so the chrome — links, the selected range pill, header accents — now uses the deep brand **blue** on Light, with **gold kept for what it means** (the Charge/recovery rings and the action button). Cards now sit on a slightly **deeper warm canvas with a stronger shadow**, so they stand out more. And on **Mac**, a sidebar glitch where the NOOP lockup overlapped the navigation list is fixed. Dark is untouched.",
            ]),
        Release(
            version: "4.3.1",
            title: "Light theme polish",
            date: "June 2026",
            items: [
                "**A handful of small details that were tuned for dark now adapt to Light too.** A theme audit caught a few chart and gauge end-cap dots, a secondary-button outline and a tooltip shadow that read faintly or invisibly on the new warm-paper canvas — they now flip to the right ink/shadow on Light. Dark is unaffected. If you switched to Light in 4.3.0 and noticed a missing dot on a graph, this is it.",
            ]),
        Release(
            version: "4.3.0",
            title: "Light theme — NOOP in warm paper & gold",
            date: "June 2026",
            items: [
                "**NOOP now has a full Light theme, and you can switch any time.** Settings → Appearance lets you pick **System** (follow your phone/Mac), **Light**, or **Dark**. The new Light look is \"warm paper & gold\" — a soft warm-white canvas with crisp navy-ink text and the signature gold deepened so it stays legible on white. Every surface was re-done for it, not just inverted: the ring gauges, frosted cards (now lifted with a soft shadow instead of a glow), charts, the scenic hero, the home-screen widget and even the status bar all adapt. Dark stays exactly as it was. Same data, same layout — your choice of finish.",
            ]),
        Release(
            version: "4.2.13",
            title: "Effort explains a calm-day zero — and scores on the 5.0/MG",
            date: "June 2026",
            items: [
                "**Effort now explains a calm-day zero instead of just showing \"0.0\".** Effort is *cardiovascular* load — it only builds while your heart rate is up in your effort zone (roughly the top half of your heart-rate reserve, often ~120 bpm and above). On a genuinely easy day your heart rate never gets there, so the honest answer really is near zero — the same way a WHOOP low-strain day reads low. The number was right, but a bare \"0.0\" looked broken, so Today now adds a short line explaining it. We also fixed the WHOOP 5.0/MG case where Effort could sit un-scored for hours: the 5.0/MG sends live heart rate far less often than a 4.0, and the gauge needed a fixed *number* of readings before it would score — now it scores once it has enough *time* of heart-rate coverage, so a steady 5.0/MG stream counts and the gauge stops falling back to a stale value. Effort still only rewards real exertion — nothing is invented. Thanks @darylbleach and @phsycology (#482, #480).",
                "**History from a long-drained strap lands on the right day again.** When a WHOOP's internal clock had fully reset — it sat uncharged so long its clock fell back to around 1970 — syncing its stored history could date every night decades into the future, silently wiping sleep and recovery from your timeline. NOOP now keeps the real timestamps in that case. Thanks @cataboysbusiness-debug (#471).",
            ]),
        Release(
            version: "4.2.10",
            title: "Week in Review is honest about a half-finished week",
            date: "June 2026",
            items: [
                "**The Week in Review summary no longer claims a \"steady week\" when you're only a day or two in.** Early in the week NOOP can't honestly call a week-over-week trend — but the summary used to read \"a steady week, nothing moved\" while the change chips right above it showed big percentage swings off those same one or two days. Now, when the current week is still sparse, the summary says something like \"Only 2 days into this week so far — too early to call a week-over-week trend yet,\" so the words match what the numbers can actually tell you. A full week with genuinely flat metrics still reads as steady. Thanks @pikapik487 (#463).",
            ]),
        Release(
            version: "4.2.9",
            title: "Respiratory rate & skin temp in the Trends report",
            date: "June 2026",
            items: [
                "**Your exported Trends report now includes Respiratory rate and Skin temperature.** Two more measured-from-the-strap rows sit alongside HRV, Resting HR, Sleep, Recovery and Strain — each with its average, range, daily trend and a per-day sparkline over the window you pick. Respiratory rate flags a rising trend as \"worth a look\" (a higher resting breathing rate can signal illness or strain); skin temperature is shown as the signed deviation from your own baseline (e.g. +0.3 °C), with no good/bad verdict — either direction can matter. Thanks @subscriptiondestroyer (#457).",
            ]),
        Release(
            version: "4.2.8",
            title: "Double-tap to log a sleep mark",
            date: "June 2026",
            items: [
                "**A new double-tap action: \"Log a sleep mark.\"** Set it in Settings → Automations, and a double-tap on your strap writes a timestamped \"Sleep mark @ 23:42\" into your strap log with a confirming buzz — mark bedtime, wake, or a mid-night wake with no screenshots and nothing to remember. It's Phase 1 (capturing the marks); tap-driven sleep bounds + personal calibration build on it. Thanks @maddognik (#461).",
            ]),
        Release(
            version: "4.2.7",
            title: "Start a workout from the Workouts screen",
            date: "June 2026",
            items: [
                "**You can now start a live workout straight from the Workouts screen** — via the centre \"+\" quick action or the Workouts tab — instead of only from the Live screen. A Start Workout button begins the session and opens the in-exercise view; if one's already running it becomes \"View active workout.\" Thanks @subscriptiondestroyer (#459).",
            ]),
        Release(
            version: "4.2.6",
            title: "\"Now\" dot sits on the trend line",
            date: "June 2026",
            items: [
                "**Fixed the glowing \"now\" dot on the Trends graphs floating below or left of the line** instead of on the latest point. It's now positioned by the chart's own coordinate system — the same one the line uses — so it lands exactly on the curve. Thanks @subscriptiondestroyer (#458).",
            ]),
        Release(
            version: "4.2.5",
            title: "Trends report explains its scores",
            date: "June 2026",
            items: [
                "**The shareable Trends report now spells out where each number comes from.** A new \"How to read this\" legend flags HRV, Resting HR and Sleep as *measured* from the strap, and makes clear that **Recovery and Strain are NOOP's own on-device scores, not clinical measures** — so it's safe to hand the PDF to a doctor or coach without your scores being mistaken for lab values. Thanks @subscriptiondestroyer (#457).",
            ]),
        Release(
            version: "4.2.4",
            title: "Trends report export now opens the share sheet (iPhone)",
            date: "June 2026",
            items: [
                "**Fixed the Trends report \"Export PDF\" doing nothing on iPhone.** The report opens in a sheet, but the share sheet was being presented behind it, so iOS silently dropped it. It now appears correctly — save the PDF to Files, AirDrop it, or send it on. Thanks @subscriptiondestroyer (#455). *(iPhone-only fix; the Mac and Android exports already worked.)*",
            ]),
        Release(
            version: "4.2.3",
            title: "Deep history backlog drains without manual taps",
            date: "June 2026",
            items: [
                "**Fixed a sync that stalled after one night and needed a strap-tap to continue.** If your strap had been fully discharged (or carried a previous owner's history), it could offload just one night per connection and then sit idle until you physically tapped it. The strap was reporting a stale \"newest record\" timestamp that read as *older* than data NOOP had already saved, so the catch-up logic wrongly stopped. NOOP now keeps draining as long as the strap is actually handing over real records and its trim cursor is advancing — so a deep backlog clears in back-to-back passes on its own. Thanks @claypilat (#451); this also fixes the manual-re-trigger half of #364.",
            ]),
        Release(
            version: "4.2.2",
            title: "Sleep stages heal themselves after a sync",
            date: "June 2026",
            items: [
                "**Fixed wrong sleep stages when you edited a night before it finished syncing.** If you corrected a night's wake time before the strap had imported that window's raw data, the stage breakdown could come out wrong — and stay wrong forever. Now the stages re-derive themselves from the real data the moment it arrives, while keeping your bed/wake correction locked. Affected nights heal automatically on the next sync. Thanks @claypilat (#449).",
            ]),
        Release(
            version: "4.2.1",
            title: "Optional inactivity nudge",
            date: "June 2026",
            items: [
                "**A gentle move reminder, if you want one.** Turn it on in Settings → Automations and NOOP will buzz your strap after you've been sitting still too long (your threshold, default 45 min), within hours you choose (default 9–5), with a re-nudge cooldown you set. It's **off by default**, runs entirely from the motion already on your strap, and respects your quiet hours and only-when-worn settings. Thanks @cbarrado (#419).",
            ]),
        Release(
            version: "4.2.0",
            title: "Open a workout, see what it costs you, and share your trends",
            date: "June 2026",
            items: [
                "**Tap a workout to open it in full.** Every session now has a detail view — its heart-rate curve over the workout, time in each HR zone, duration, avg/max HR, and the Effort it added — so you can actually look back at a session, not just see it in a list. Thanks @andreasc1 (#410).",
                "**Activity Cost: learn what each activity actually costs your recovery.** A new Insights section correlates your tagged activities with the next morning's Charge — \"sessions like this usually cost you about N points and take about D days to bounce back\" — measured against your own untouched rest-day baseline, with a confidence level so it only speaks up once it's seen enough. Thanks @subscriptiondestroyer (#439).",
                "**Shareable trends report.** Export a clean one-page PDF of your recovery, sleep, HRV, resting HR and strain over a range you choose (30 days to all-time) — for a doctor, a coach, or your own records. Entirely on-device, shared through the system share sheet. Thanks @subscriptiondestroyer (#436).",
                "**Last night syncs sooner.** When a deep backlog is still draining, NOOP now keeps the sync going while you're connected instead of stopping and waiting 15 minutes between bursts — so recent nights arrive in far fewer sessions. There's also a **Sync now** button to kick a backfill on demand. Thanks @idkwargwanbear (#364).",
                "**Weight from Health Connect now shows in Compare** (Android) — a Health-Connect-only weight history was invisible there before. (#443)",
            ]),
        Release(
            version: "4.1.1",
            title: "Hotfix — making a heart-rate strap active no longer crashes",
            date: "June 2026",
            items: [
                "Fixed a crash where activating a generic heart-rate strap could take the app down (Android). Thanks @pilleuspulcher-blip (#421).",
            ]),
        Release(
            version: "4.1.0",
            title: "Estimated steps for your WHOOP 4.0",
            date: "June 2026",
            items: [
                "**Steps on a WHOOP 4.0 — estimated, and calibrated to *you*.** A WHOOP 4.0 doesn't send a step count over Bluetooth, so NOOP now *estimates* your daily steps from the strap's own motion and calibrates that estimate against your phone's step count (Apple Health / Health Connect) — learning a coefficient personal to your gait and how the band rides. It's honest about what it is: an **estimate**, never a pretend pedometer — shown with an \"est.\" marker, and \"—\" when there isn't enough movement to say.",
                "**A Steps calibration screen** (Settings → Profile → Steps estimate): see your estimate next to your phone's real count side-by-side, how confident the fit is, and a **manual dial** to tune it to you, with a live preview. No phone steps to calibrate against? Set the dial by hand.",
                "Where you do have a real phone step count, that always wins — the estimate only fills the days your phone didn't cover.",
                "**Generic heart-rate straps now actually connect.** A Polar / Wahoo / Coospo strap you made active was being *discovered* but never *connected to* — so it sat there with no live data. Fixed: NOOP now connects straight to your selected strap. Thanks @pilleuspulcher-blip (#421).",
                "**The strap log is now safe to share.** It no longer exposes your WHOOP's serial or Bluetooth MAC addresses — they're masked automatically, so you can paste a diagnostic log on GitHub without leaking identifiers. Thanks @maddognik (#445).",
            ]),
        Release(
            version: "4.0.4",
            title: "Sync visibility + a sharper Stress timeline",
            date: "June 2026",
            items: [
                "**Sync diagnostics: the strap log now shows the newest record your band actually holds.** For \"last night didn't sync\" reports, one connect now tells us whether the night simply hasn't been reached yet by a long backlog (it's banked, the sync is still grinding toward it) versus genuinely not on the strap — instead of guessing. Thanks @idkwargwanbear (#364).",
                "**Android: the Today stress timeline gets a Y-axis and tap-to-read.** The day's stress chart now has labelled levels and you can scrub it to read each hour. Thanks @ujix (#441).",
            ]),
        Release(
            version: "4.0.3",
            title: "Date fixes, UI polish & clearer diagnostics",
            date: "June 2026",
            items: [
                "**Today's date now matches Intelligence History.** On Android, the Today/Recovery screen could label a day with one date while showing the previous day's numbers (when this morning's recovery wasn't scored yet) — so it disagreed with the same day in Intelligence History. The Today date now names the row actually on screen, matching Intelligence and the Mac/iPhone behaviour. Thanks @pikapik487 (#434).",
                "**Clearer diagnostics for non-WHOOP heart-rate straps.** Connecting a generic strap (Polar, Wahoo, Coospo…) now records every step of the Bluetooth handshake in the strap log — scan, connect, service discovery, notification enable, first reading — so a \"connected but no data\" report can actually be diagnosed instead of showing only WHOOP activity. Adds a single auto-retry on the common Android `133` connect error. Thanks @pilleuspulcher-blip (#421).",
                "**UI polish (Android):** the \"vs previous month\" comparison in Explore no longer clips; the bedtime/wake time-scale label isn't cut off; the Insights day order is now Yesterday → Today → Tomorrow; and the \"Journal\" heading stays on one line. Thanks @nhe (#443).",
            ]),
        Release(
            version: "4.0.2",
            title: "Switching between WHOOP straps now actually switches",
            date: "June 2026",
            items: [
                "**Multi-WHOOP: switching the active strap now moves the connection to it.** If you had more than one WHOOP paired and switched the active one, the app could keep streaming the *previous* strap while showing the new one — because on reconnect it re-attached to whatever your system already had open, instead of the strap you selected. It now lets go of the old strap and connects to the one you picked (Mac & iPhone), and the WHOOP 5/MG bonded fast-path on Android honours your selection the same way. Single-WHOOP setups are unaffected.",
            ]),
        Release(
            version: "4.0.1",
            title: "Today's Effort goes live — plus sleep & alarm honesty",
            date: "June 2026",
            items: [
                "**Today's Effort now updates live through the day.** The Effort ring recomputes over today's heart rate as it happens (midnight → now), instead of showing yesterday's completed-day value — or a stale 0.0 early in the morning — until the next full re-score. Thanks @rad182 (#402).",
                "**Editing a sleep time can't scramble the night any more.** The wake picker now keeps the night on its own day, so correcting a bed/wake time re-derives that night's stages cleanly instead of splitting the corrected block and its totals across two days. Resting-HR + HRV day-bucketing was also aligned across Mac, iPhone and Android. Thanks @ujix (#406).",
                "**Late nights and long lie-ins are captured** — the sleep-detection window was widened so a wake after noon isn't cut short. Thanks @ujix (#425).",
                "**Smart alarm is now honestly flagged experimental.** The strap acknowledges the alarm, but a strap-driven wake hasn't been verified firing yet — on WHOOP 4.0 *or* 5/MG — so the app now asks you to keep a backup alarm while we confirm the exact firmware buzz pattern. Thanks Kaliarti (#428).",
                "**Android: rename your WHOOP's Bluetooth name** — brings Android up to the iPhone/Mac feature. Thanks @cbarrado (#422).",
                "**Polish from a full code review:** your Vitality breakdown now reconciles exactly with the Body Age number it explains; the new Age cards always compute on Android (the age control is bounded like iPhone/Mac); renaming no longer spins forever if your strap doesn't answer; and live workout detection now covers the whole calendar day. Thanks @rad182, @cbarrado, @j0b-dev.",
            ]),
        Release(
            version: "4.0.0",
            title: "Your Fitness Age, Vitality & Body Age",
            date: "June 2026",
            items: [
                "**Fitness Age — a weekly number for how fit your heart is.** NOOP now estimates your **Fitness Age** from your resting heart rate and recent activity, and shows it against your real age — “35, four years younger than your calendar age.” Built on the published Nes/HUNT VO₂max model. Tap **“How accurate is this?”** to see exactly which of your inputs went in, grouped by what each one unlocks — we’re honest that it’s a fitness comparison, not a biological age.",
                "**Vitality + Body Age — your longevity number.** A weekly **0–100 Vitality** score and a **Body Age in years**, built the way WHOOP’s Healthspan is: your resting HR, sleep duration + regularity, HRV, and activity, each weighed against published all-cause-mortality research, then turned into “how old your habits make your body.” It even tells you the **one thing helping most** and the **one holding you back**. A wellness trend — **never** a clinical or medical age.",
                "**Optional: see your estimated VO₂max.** Add your waist measurement in Settings and NOOP will also show an estimated VO₂max alongside your Fitness Age. (Your Fitness Age itself never needs it.)",
                "**Honest by design.** Every new number carries a ± band and a plain “this is a wellness estimate, not a clinical age” line. These build over a week or two of wear and sharpen as NOOP learns your baseline.",
            ]),
        Release(
            version: "3.9.1",
            title: "A round of fixes — reconnect, exports & Health setup",
            date: "June 2026",
            items: [
                "**Mac & iPhone reconnect on their own.** If your strap briefly dropped out of range (or a connection attempt failed mid-handshake), the app used to just sit there until you reconnected by hand. It now keeps retrying on its own with a gentle back-off, and stops the moment it's back. Thanks @phsycology (#414).",
                "**Android: GPS workouts write back to Health Connect.** Workouts you track in NOOP weren't being saved to Health Connect — we'd never asked for the exercise-write permission, so the system quietly dropped them. Fixed; you'll be asked once to allow exercise + distance. Thanks @andreasc1 (#412).",
                "**Raw sensor export no longer runs out of memory.** Exporting the raw-sensor CSV from a busy 24 hours could fail with an out-of-memory error. It now streams straight to the file as it goes, so it works no matter how much data you've gathered. Thanks @maddognik (#406).",
                "**Android: sleep stage breakdown reads cleanly.** The stage-breakdown figures under the sleep chart no longer wrap onto a second line and clip against the card edge (#406).",
                "**WHOOP 4.0: no more phantom deep-data counter.** The experimental deep-data packet counter is a WHOOP 5/MG feature — it no longer ticks up on a 4.0, where those packets mean something else (#346).",
                "**Under the hood:** documented the 5-class (MAVERICK) command numbers in the protocol reference. Thanks @j0b-dev (#418).",
            ]),
        Release(
            version: "3.9.0",
            title: "Manage several WHOOP straps — and see what each band does",
            date: "June 2026",
            items: [
                "**Manage several WHOOP straps.** Got more than one WHOOP — a couple of 4.0s, a 5.0, or a mix? NOOP now tells them apart and lets you **pair, switch, rename and remove** each one from the **Devices** screen. Only one strap is ever active at a time, and your history is never mixed between devices.",
                "**A guided way to add a device.** “Add a device” now **asks what you're adding** — WHOOP 5.0/MG, WHOOP 4.0, or a heart-rate strap — and walks you through the right pairing steps for that band (a 5/MG pairs differently from a 4.0).",
                "**The Live screen points to your devices.** The live console now shows **which band is active** and has a **Manage devices** shortcut, so it's obvious where to go to pair or switch straps.",
                "**Every device card now says what it actually does.** Each band shows **what it captures and what NOOP uses it for** — so it's clear at a glance that, say, a 5/MG reports steps while a 4.0 doesn't. We also made the labels honest: no “Blood oxygen” where NOOP can't read an SpO₂ percentage off the strap (it never can — a real % only comes from a WHOOP CSV import), and skin temp / respiration are marked as the on-device estimates they are.",
            ]),
        Release(
            version: "3.8.0",
            title: "Connect a heart-rate strap (early access)",
            date: "June 2026",
            items: [
                "**A new Devices screen.** NOOP can now read more than just a WHOOP. Pair a **standard Bluetooth heart-rate strap** — Polar, Wahoo, Coospo, a Garmin HRM, or the Amazfit Helio's heart-rate broadcast — for **live heart rate + HRV**. Manage everything under **Devices**: see what's paired, switch which strap is active, rename or remove one.",
                "**WHOOP stays the primary, fully-supported band.** Other straps are an early, opt-in addition — they stream live HR + HRV, but not WHOOP's deeper sleep, recovery and strain. Only one strap is ever active at a time, and NOOP never mixes data from two devices.",
                "**Early and experimental.** This is the first build that talks to non-WHOOP straps, so the live connection is still being proven on real hardware — pair one, tell us how it goes, and grab a strap log if it misbehaves. Your WHOOP setup is completely unchanged.",
            ]),
        Release(
            version: "3.7.1",
            title: "Tidier Today gauges",
            date: "June 2026",
            items: [
                "**iPhone/Mac:** the three **Charge / Effort / Rest** rings on Today no longer render squished, with their state word (LOW / MODERATE / PEAK) overlapping the arc, on larger iPhones. Each ring now sizes to its card and the labels scale to fit (still full-size on the big single-score rings, and still scaling with your accessibility text size). Thanks @claypilat (#403).",
                "**Under the hood:** groundwork for connecting more than one device — no change to your current setup.",
            ]),
        Release(
            version: "3.7.0",
            title: "A round of fixes — steps, Insights & Health setup",
            date: "June 2026",
            items: [
                "**Step calibration goes further:** on a WHOOP 5/MG the strap's motion counter can over-report steps by 20× or more, and the calibration dial used to stop at 4×. It now goes all the way to **30×**, and the +/− control takes bigger jumps the higher you go — so you can dial in a large correction in a few taps instead of dozens. Thanks @exzanimo (#132).",
                "**Insights “By Day” stays smooth with years of history:** tapping **All** with a big imported history used to build every day at once and could freeze the app. The list now renders only what's on screen, so it scrolls smoothly no matter how many days you've imported. Small histories look and feel identical. Thanks @maddognik (#345).",
                "**Honest Apple Health guidance on free sideloads:** if you installed NOOP with a free Apple ID (AltStore / Sideloadly), the build can't be granted Apple Health access at all — so instead of pointing you to a Settings screen NOOP can never appear in, it now tells you straight and routes you to the file-import / Shortcuts path. Properly-signed installs are unchanged. Thanks @exzanimo (#348).",
                "**Better odds of unlocking newer straps:** the on-device archive that collects undecoded history frames (so new firmware layouts can be reverse-engineered) now keeps a guaranteed sample of **each distinct layout version**, so a rare new one — WHOOP 4.0 v19, 5/MG v20/v21 — can't be crowded out before we can study it. Thanks @airtonzanon and everyone sending logs (#344).",
            ]),
        Release(
            version: "3.6.0",
            title: "A fresh look — new gold-on-navy icon",
            date: "June 2026",
            items: [
                "**New app icon (everywhere):** a bolder take on the Titanium & Gold mark — a thick **gold recovery ring + core** on deep navy, across iPhone, Mac and Android (and the in-app logo). Same NOOP, sharper identity.",
                "**Android — sleep corrections now stick:** bringing Android up to iPhone/Mac — when you hand-correct a night's bed/wake times, the correction now **survives the next strap sync** instead of quietly reverting (the edited night is no longer re-derived over, and editing the bedtime no longer risks a duplicate row).",
            ]),
        Release(
            version: "3.5.0",
            title: "Hand-correct your sleep times + smaller backups",
            date: "June 2026",
            items: [
                "**Sleep (iPhone/Mac):** auto-detection sometimes reads the wrong bed or wake time — now you can fix it. Tap the **pencil** on the Sleep tab to correct a night's **Asleep / Woke** times, and NOOP re-stages the night from the raw sensor data over your corrected window. The correction **sticks** — a later strap sync won't quietly revert it. (For an imported WHOOP-export night, the displayed times update but its recovery/performance stay as WHOOP recorded them.) Thanks @claypilat (#395).",
                "**Smaller, shareable backups:** exporting your data now produces a compressed **`.noopbak`** file — typically **80–90% smaller** (a 100 MB+ backup becomes ~10–20 MB), small enough to AirDrop, message or email. iPhone, Mac and Android all read each other's, and your older uncompressed backups still import fine. Thanks @ujix (#396).",
            ]),
        Release(
            version: "3.4.0",
            title: "Tidier Today hero, strap renaming, smarter journal",
            date: "June 2026",
            items: [
                "**Today:** your three daily scores — **Charge / Effort / Rest** — now sit in one tidy row of rings, instead of leaving Rest stranded on its own line beside an empty space. Thanks @vulnix0x4 (#394).",
                "**WHOOP 4.0 — rename your strap (iPhone/Mac):** picked up a second-hand band stuck on the previous owner's name? You can now rename its Bluetooth advertising name under **Settings → Strap** while it's connected. The strap reboots to apply, and it's reversible any time. Thanks @rad182 (#393).",
                "**Android journal:** opening today's journal now **pre-fills last night's answers** (one tap to confirm or change — recurring habits like \"read before bed\" no longer need re-entering), with bigger Yes/No tap targets. Thanks @ujix (#372).",
            ]),
        Release(
            version: "3.3.1",
            title: "More quick-relabel sports",
            date: "June 2026",
            items: [
                "Added **CrossFit, Hiking and Tennis** to the quick re-label list when you change a detected workout's type (on every platform). More workout-management discoverability improvements are on the way. Thanks @marceauboul (#318).",
            ]),
        Release(
            version: "3.3.0",
            title: "Strap battery alerts",
            date: "June 2026",
            items: [
                "New: NOOP can now alert you when your WHOOP's battery runs **low (15% or below)** or finishes **charging (100%)** — a simple system notification so you don't get caught out before bed. It fires at most once per discharge and once per charge (a small re-arm band means a battery hovering near 15% won't nag you), and it's on by default — turn it off any time under Settings → Automations. All three platforms. Thanks @ujix (#368).",
            ]),
        Release(
            version: "3.2.0",
            title: "Under-the-hood: current-API migration (no behaviour change)",
            date: "June 2026",
            items: [
                "Maintenance release: migrated the iPhone/Mac UI to the current iOS 17 / macOS 14 SwiftUI and Charts APIs (replacing two deprecated calls), behind a small compatibility shim so the Mac build still runs on macOS 13. Nothing changes for you — it's a cleaner, warning-free build that's better set up for future OS versions. Android is versioned in lockstep with no Android-facing change. Thanks @vulnix0x4 (#331).",
            ]),
        Release(
            version: "3.1.0",
            title: "Accuracy, reliability & accessibility — a big community-fixes wave",
            date: "June 2026",
            items: [
                "Smart alarm: it now re-arms every day, so a strap that stays connected keeps waking you past the first morning (iPhone, Mac and Android). On WHOOP 5/MG the strap's firmware alarm correctly stays behind the Experimental toggle until it's confirmed. Thanks @vulnix0x4 (#376, #379).",
                "More honest numbers: workout calories now count sparse heart-rate streams properly without ever over-counting your whole day; heart-rate zones are no longer inflated by a gap when the strap is off your wrist; daytime stress no longer false-alarms from your overnight sleep; and the recovery baseline reads your imported data cleanly. Thanks @vulnix0x4 (#360, #366, #357, #387).",
                "Bluetooth & live HR: WHOOP 5/MG keeps decoding correctly after iOS relaunches NOOP in the background, and the Lock-Screen / Dynamic-Island live heart rate now ends when the strap disconnects instead of freezing on a stale number. Thanks @vulnix0x4 (#378, #386).",
                "Your data is safer: a failed import now keeps your existing data instead of risking an empty database, and the AI Coach never sends an API key you saved for one provider to a different one. Thanks @vulnix0x4 (#383, #385).",
                "Accessibility & polish: the breathing orb honours Reduce Motion, the 24-hour heart-rate chart reads out in VoiceOver, text scales with Dynamic Type, the day navigator has bigger tap targets, and Sleep/Stress times follow your device's 12/24-hour and language settings. The Today screen also stays smooth while live heart rate streams. Thanks @vulnix0x4 (#359, #362, #381, #363, #361, #388, #358).",
                "Android: workout rows are now tappable with a detail sheet, and the sleep-consistency tile no longer reads a false 0% — thanks @ujix (#370, #367). The Rest confidence dot now matches iPhone/Mac (#373). Plus an accurate Mac menu-bar live-feed toggle, and \"What's New\" no longer gets skipped after an update that also refreshes the Terms (#390, #389).",
            ]),
        Release(
            version: "3.0.3",
            title: "Large Apple Health imports no longer crash (iPhone/Mac)",
            date: "June 2026",
            items: [
                "Fixed (iPhone/Mac): importing a large, multi-year Apple Health export no longer runs out of memory and closes the app. The importer now aggregates your data day-by-day as it reads, instead of holding every sample in memory at once — so even years of Apple-Watch heart-rate import cleanly. It also accepts a localised export filename (e.g. a Russian export's \"экспорт.xml\") instead of requiring it to be renamed to \"export.xml\". Thanks @exzanimo (#355).",
            ]),
        Release(
            version: "3.0.2",
            title: "Bluetooth stream + Apple Health sync fixes",
            date: "June 2026",
            items: [
                "Fixed: a corrupt or mis-aligned Bluetooth frame could wedge the live data stream until you reconnected — NOOP now spots an impossible frame length and resyncs to the next real frame instead of stalling. Thanks @vulnix0x4 (#374).",
                "Fixed (iPhone): the two-way Apple Health sync was reading its OWN written-back values back in as \"Apple Health\" data — which could make your strap and Apple Health plot the same line, and skew the Apple-Health average if you also wear a watch. It now excludes NOOP's own samples on read, and a failed sync no longer reports a false \"success\". Thanks @vulnix0x4 (#375).",
            ]),
        Release(
            version: "3.0.1",
            title: "Cleaner score rings + a few fixes",
            date: "June 2026",
            items: [
                "Changed: removed the small gold dot in the centre of the Charge / Recovery rings, behind the number — at the v3 launch a few of you (rightly) said it crowded the read-out. The clean ring + number + micro-NOOP wordmark stay; the dot now lives only in the standalone logo.",
                "Fixed: Steps on Today now prefer your strap's own on-device step count (WHOOP 5/MG) over Apple Health, matching Android — so strap-only users see their steps without importing anything. Thanks @netizentryingtofitin (#276).",
                "Fixed: a real overnight sleep that runs late, or has a brief morning stir then drifts back to sleep, no longer truncates your wake time to late morning (\"woke at noon\"). Your true wake time is kept. Thanks @vulnix0x4 (#353).",
                "Fixed (Android): the HR-zone coaching toggle now actually persists and buzzes your strap when you cross into your top zone — and again as you recover — closing the gap with Mac/iPhone. It was previously a preview-only stub. Thanks @cbarrado (#350).",
            ]),
        Release(
            version: "3.0.0",
            title: "A whole new look — \"Titanium & Gold\"",
            date: "June 2026",
            items: [
                "New: NOOP's biggest redesign yet — \"Titanium & Gold\". A deep-navy canvas, a warm gold accent, brushed-titanium detail and a per-domain colour world (blue sleep, amber strain, teal HRV, burnt-orange stress), in Helvetica, across iPhone, Android and Mac.",
                "New: a brand-new machined-titanium app icon with a gold core — plus a Settings → App Icon toggle to switch to a darker \"blued-titanium\" version.",
                "New: a refreshed in-app brand mark on the splash, onboarding and navigation.",
                "Polish: a consistency pass across every screen — tidier cards, cleaner date selectors (no more dark-yellow blocks), smoother transitions, and a tab bar where the centre \"+\" sits in its own space. Live heart rate now lives on the \"+\" quick-actions menu.",
            ]),
        Release(
            version: "2.18.5",
            title: "Today tiles no longer cut their value to \"10…\" (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): on phones, Today tiles that show a sparkline (Charge, Rest, Respiratory, HRV…) were truncating their value to \"10…\" or \"15…\" because the value and the inline trend line were competing for width. The value now shrinks to fit the way it already does on Mac/iPhone, so it always reads in full. Thanks @asemfahad (#332).",
            ]),
        Release(
            version: "2.18.4",
            title: "Dynamic Island toggle now actually turns it off",
            date: "June 2026",
            items: [
                "Fixed: turning off \"Live heart rate in Dynamic Island\" in Settings now genuinely removes it. Previously, if the heart had started in a past app session, the in-app toggle couldn't reach it to switch it off — only the iOS system switch worked. The app now re-adopts an already-showing Live Activity so the toggle ends it straight away. iPhone only. Thanks @gingerbeardman (#341).",
            ]),
        Release(
            version: "2.18.3",
            title: "Workouts header layout fix (phone)",
            date: "June 2026",
            items: [
                "Fixed: on the Workouts screen, the \"Add workout\" button was being crushed into a tall sliver next to the 7D/30D/90D range selector on phones. The button and the range selector now stack cleanly. Thanks @RichrdJ (#339).",
            ]),
        Release(
            version: "2.18.2",
            title: "Times follow your 12-/24-hour setting",
            date: "June 2026",
            items: [
                "Times now follow your device's 12-/24-hour setting. The heart-rate chart tooltip and the workout time ranges showed a fixed 24-hour clock (e.g. 19:10); they now read 7:10 PM where you prefer 12-hour, or stay 19:10 where you prefer 24-hour. Thanks @rad182 (#337).",
            ]),
        Release(
            version: "2.18.1",
            title: "Toggle the live-HR Dynamic Island",
            date: "June 2026",
            items: [
                "New (iPhone): a toggle to keep your live heart rate out of the Dynamic Island and Lock Screen — Settings → Strap → \"Live heart rate in Dynamic Island\". On by default; flip it off and any live-HR activity already showing clears within a moment. Thanks @gingerbeardman (#336).",
            ]),
        Release(
            version: "2.18.0",
            title: "Export your raw sensor data (CSV)",
            date: "June 2026",
            items: [
                "New (experimental): Settings now has an Export raw sensor data (CSV) button — it dumps the decoded per-sample streams NOOP already stores (heart rate, R-R, accelerometer, the motion/step counter, SpO2/PPG and events) for the last 24h as a plain CSV. It's for tinkerers: prototype your own sleep / activity / VBT algorithms on real data, no BLE coding needed. On-device only, nothing leaves your phone unless you share it. Thanks @maddognik / @alacore (#322/#276).",
            ]),
        Release(
            version: "2.17.1",
            title: "Charge shows \"Calibrating\" instead of \"No data\" for new straps",
            date: "June 2026",
            items: [
                "Charge no longer shows a bare \"No data\" while it is still learning your baseline. A brand-new strap now reads \"Calibrating — 0 of 4 nights\" so it is clearly building, not broken — Charge needs a few nights of wear before it can score recovery (Effort and Rest show right away). Thanks @umarXBT (#335).",
            ]),
        Release(
            version: "2.17.0",
            title: "iPhone polish + accessibility",
            date: "June 2026",
            items: [
                "iPhone: the floating tab bar no longer hides the last card on scrolling screens — there's now room to scroll the final card fully clear. Thanks @vulnix0x4 (#333).",
                "iPhone: tappable cards now give a subtle press response + a light haptic (before, they only reacted to a mouse pointer), and the manual-workout sheet uses a proper drag-handle + a decimal keypad with a Done button. Thanks @vulnix0x4 (#329, #330).",
                "Accessibility: charts now read a one-line VoiceOver summary (e.g. \"Charge trend — 35 points, mean 62, range 22 to 91\"), and the gauge draw-in animation respects Reduce Motion. Thanks @vulnix0x4 (#334).",
            ]),
        Release(
            version: "2.16.1",
            title: "Today tiles no longer truncate their value (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): some Today tiles cut their value off to \"…\" (Effort, Rest, Respiratory, and the Last Workouts durations) — the value now shrinks to fit the tile instead of truncating, matching the Mac/iPhone behaviour. Thanks @asemfahad (#332).",
            ]),
        Release(
            version: "2.16.0",
            title: "A round of look-and-feel polish",
            date: "June 2026",
            items: [
                "Sleep: a clearer hypnogram — short stages (like Awake) read as bars instead of ticks, Deep is more legible on the dark card, and a time axis marks onset / midpoint / wake. Thanks @vulnix0x4 (#323).",
                "Live: when no strap is connected, Scan & Connect is now front-and-centre instead of buried, the redundant \"Offline\" badge is gone, and idle tiles read a calm \"Offline\". Thanks @vulnix0x4 (#325).",
                "Trends: cleaner — the reading-count shows once, footers read naturally (\"Mean 69 ms\"), tiny week-over-week moves read \"<1%\", and peaks no longer clip the top of the chart. Thanks @vulnix0x4 (#326).",
                "Effort: the Effort gauge and accents now brighten across the full amber ramp (a maxed-out day no longer stays dark ember), and the Week-in-Review Effort gauge honours your 0–100 / 0–21 preference. Thanks @vulnix0x4 (#328).",
            ]),
        Release(
            version: "2.15.3",
            title: "Android GPS route distance fix",
            date: "June 2026",
            items: [
                "Fixed (Android): GPS workouts could record a route far shorter than reality — a real run saved as only tens of metres. The route filter was dropping too many legitimate fixes on weaker GPS signal; it now keeps the points it should, so distance and route record properly. Thanks @don86nl (#324).",
            ]),
        Release(
            version: "2.15.2",
            title: "Today header date fix (west-of-UTC)",
            date: "June 2026",
            items: [
                "Fixed: the Today header date could read one day behind the day-nav pill (e.g. \"Saturday, 13 June\" under a \"14 Jun\" pill) for anyone in a timezone west of UTC — it now matches the pill. Thanks @vulnix0x4 (#320).",
            ]),
        Release(
            version: "2.15.1",
            title: "Last Workouts tile fix",
            date: "June 2026",
            items: [
                "Fixed (Android): the **Last Workouts** tiles on Today no longer truncate the workout duration to \"1…\" — the duration now gets the room it needs next to the calorie chip. Thanks @nhe (#319).",
            ]),
        Release(
            version: "2.15.0",
            title: "The new look everywhere — plus sleep, Effort & Bluetooth fixes",
            date: "June 2026",
            items: [
                "The new look, everywhere: every screen now wears NOOP's premium dark design — scenic backdrops, glowing ring gauges and frosted per-domain cards across Sleep, Recovery, Stress, Workouts, Live, Health, Trends, Insights, Breathe, Coach and Settings, on Mac, iPhone and Android.",
                "Fixed (sleep day): if you fall asleep before midnight and wake before ~4am in a timezone other than UTC, Today now shows last night's sleep instead of the night before. Thanks @maddognik (#304).",
                "Fixed (sleep detection): on WHOOP 5.0 a full night is no longer chopped into tiny fragments and dropped — NOOP now holds the night together from your heart rate when motion data is sparse. Thanks @umarXBT (#308).",
                "Fixed (Effort scale): the Effort gauge on Today, Live and Workouts now follows your 0–100 / 0–21 preference instead of always showing 0–21, and older imported days are re-scored onto the 0–100 axis. Thanks @maddognik (#313).",
                "Fixed (Android Bluetooth): turning Bluetooth off — or flight mode — no longer leaves NOOP showing a phantom \"connected\" or crashing on the next buzz; it now cleanly shows disconnected and reconnects when Bluetooth returns. Thanks @pilleuspulcher-blip (#314).",
            ]),
        Release(
            version: "2.14.1",
            title: "Continuous workouts no longer split",
            date: "June 2026",
            items: [
                "Fixed: a long, continuous workout — like a 4-hour ride — no longer fragments into several tiny separate workouts. The auto-detector now stitches a sustained effort back into one session across brief dips and short signal drops, while a genuine rest still ends the workout. Thanks @ck090 (#303).",
            ]),
        Release(
            version: "2.14.0",
            title: "A beautiful new look",
            date: "June 2026",
            items: [
                "NOOP has a **gorgeous new design** — deeper, calmer, more premium. A dark blue-black canvas, **layered ring gauges** for your Charge, Effort and Rest scores with glowing accents, **frosted tinted cards**, and a refreshed Today. Same data, same on-device privacy — it just looks the way it always should have. More screens get the full treatment over the coming updates.",
            ]),
        Release(
            version: "2.13.0",
            title: "A big iPhone update — and a WHOOP-style Today chart for everyone",
            date: "June 2026",
            items: [
                "New: a **WHOOP-style Overview chart** on Today — your 24-hour heart rate now carries a sleep band, your Charge at wake, your Effort now, and a glyph at each workout's peak. Thanks @rad182.",
                "New: the **Sleep** screen now shows your **asleep and woke times** at a glance. Thanks @vulnix0x4.",
                "New (iPhone): **two-way Apple Health** you can actually turn on — enable it on the Apple Health screen and your NOOP recovery, HRV, resting HR and more flow to Health (now including strap-only users), with the Apple Health screen finally populating. Thanks @vulnix0x4.",
                "New (iPhone): a proper **accessibility pass** — VoiceOver reads the charts, tiles and controls, **Reduce Motion** is respected throughout, and touch targets meet the 44pt minimum. Thanks @vulnix0x4.",
                "New (iPhone): **pull-to-refresh** on the main screens, the **screen stays awake** plus **haptics** during Breathe and Interval sessions, a **Siri & Shortcuts** screen, a readable iPad layout, and background strap reconnect via CoreBluetooth state restoration.",
                "Fixed (iPhone): Apple Health workout counts, secondary screens now refresh after a sync, the Compare chart is readable by touch, 'Mark a Moment' stamps the right time, and a long list of platform-correct copy + layout polish. Thanks @vulnix0x4 and @khalilkm01.",
            ]),
        Release(
            version: "2.12.0",
            title: "Continuous HRV capture — sharper overnight HRV, recovery and sleep",
            date: "June 2026",
            items: [
                "New (opt-in): **Continuous HRV capture.** Your strap streams dense beat-to-beat heart-rate variability in the clear — but apps usually only listen while a live screen is open, so overnight, when HRV, recovery and sleep need it most, the data goes quiet. Turn this on (**Settings → Strap**) and NOOP keeps the stream open in the background, banking roughly an interval a second all night for much sharper overnight HRV, recovery and sleep — especially on WHOOP 5.0/MG. It uses more battery, so it's off by default and entirely your call. Big thanks to @Extazian, whose reverse-engineering proved this is reachable without touching anything encrypted.",
            ]),
        Release(
            version: "2.11.1",
            title: "Fix: your day now follows your timezone, not UTC",
            date: "June 2026",
            items: [
                "Fixed: on phones away from UTC — most of the world — the dashboard could appear to **freeze partway through the day**: new steps and readings stopped showing even though the strap was syncing perfectly. NOOP was filing each day by UTC midnight instead of *your* local midnight, so once your clock crossed the UTC boundary, fresh data landed in the next day's bucket where the screen wasn't looking. NOOP now buckets every day by your local day, everywhere. Thanks @Meriquium (#277).",
            ]),
        Release(
            version: "2.11.0",
            title: "A smart wake alarm, live workout mode, an editable Today, and lifting imports",
            date: "June 2026",
            items: [
                "New (Android): a **smart wake alarm** — set a wake window and NOOP wakes you on a lighter sleep phase inside it, with a guaranteed alarm at the end of the window. The guaranteed wake is a real OS alarm that fires even if Bluetooth drops or the app is closed. Thanks @subscriptiondestroyer (#207).",
                "New: an evening **wind-down nudge** on every platform — a gentle reminder, timed from your usual wake time and sleep need, that it's time to start winding down. (A sideloaded iPhone/Mac app can't sound a dependable wake alarm, so those get the nudge, not the wake alarm.)",
                "New: **live workout mode** — a full-screen in-exercise view with big live heart rate, your current HR zone, elapsed time and live effort. Thanks @subscriptiondestroyer (#238).",
                "New: **editable Key Metrics** — choose which tiles appear on Today and reorder them to taste. Thanks @umarXBT (#251).",
                "New: an **Effort scale toggle** — show Effort on NOOP's 0–100 axis or WHOOP's familiar 0–21 Day-Strain axis, everywhere it appears. Display-only; your stored data is unchanged. Thanks @umarXBT (#268).",
                "Improved: the **sleep hypnogram is smoother** — brief sub-3-minute stage flecks merge into their neighbours so the graph reads cleanly, biased toward the lighter stage so it never inflates Deep or REM. Thanks @umarXBT (#274).",
                "New: **import your lifting log** from Hevy (CSV) or Liftosaur (JSON) — each workout lands as a Strength session with an honest training volume-load (weight × reps), kept separate from your heart-rate Effort. On-device, nothing uploaded. Thanks @marceauboul and @maddognik (#272/#232).",
            ]),
        Release(
            version: "2.10.0",
            title: "Sleep-debt, daytime stress, a recovery forecast, and day-by-day navigation",
            date: "June 2026",
            items: [
                "New: a **sleep-debt ledger** on the Sleep screen — a running 14-night balance of how much sleep you've banked versus your personal need, with a plain-English read and a per-night chart.",
                "New: a **daytime stress timeline** on the Stress screen, built from the day's heart rate and R-R — with a gentle nudge toward a Breathe session when it stays elevated.",
                "New: a **recovery forecast** on the Intelligence screen — an evening estimate of tomorrow morning's Charge from today's effort, your planned sleep and your recent baseline. Clearly an estimate, with an error band, shown once there's enough history.",
                "New: **navigate Today day by day** — chevrons and a date-picker jump replace the fixed 3-day selector, on every platform.",
                "New (Android): a live **strap-battery %** and **recorded-nights streak** on the Today header.",
                "Improved (iPhone/Mac): the Live tab is noticeably **smoother** — the rapid strap stream no longer re-renders the whole screen on every frame.",
                "Fixed (iPhone): tidied the Today Synthesis card alignment and the manual-workout field widths.",
            ]),
        Release(
            version: "2.9.0",
            title: "Background GPS, sleep-time editing, log-ahead, and a sharper Rest tile",
            date: "June 2026",
            items: [
                "Fixed (Android): GPS workouts kept tracking with the screen off. Distance was under-counting badly (a 2.8 km ride logged as 0.4 km) because tracking ran on the screen — it now runs in the always-on background service, so your route survives the screen turning off and the phone going in a pocket. Thanks @pilleuspulcher-blip (#215).",
                "Fixed: the 'Rest' tile on Today now shows your Rest SCORE (out of 100, like Charge and Effort), with hours-in-bed kept as the caption — it was showing the hours where the score should be. Thanks @subscriptiondestroyer (#248).",
                "New (Android): the Sleep screen gains in-app bed/wake-time editing — fix a mis-detected night and every metric recomputes live — plus Hours-vs-Needed and Sleep-Consistency cards, night-by-night navigation, and tappable metric details. Thanks @ujix.",
                "New: log journal entries for **tomorrow**, not just today and yesterday — today's activities inform tomorrow's recovery. Thanks @Eph00n (#237).",
                "Fixed (iPhone): the Explore list could appear empty even though the data was there — it now renders immediately with a brief 'scanning' hint instead of a blank list. Thanks @sebastianwoo (#199).",
                "Improved: body vitals now show which source each reading came from (your WHOOP, NOOP's own computation, or Apple Health) and merge them field-by-field instead of letting one source blank the others. Thanks @khalilkm01.",
                "New (Android): tap-and-drag to inspect the Stress chart, and a cleaner Explore metric picker. Thanks @ujix.",
                "New: an optional, read-only local access package (MCP) for power users who want to query their own on-device NOOP data from local tools — opt-in, nothing leaves the device. Thanks @khalilkm01.",
                "Also fixed a heart-rate-ingest crash on startup that a community ADB log surfaced. Thanks @maddognik (#224).",
            ]),
        Release(
            version: "2.8.9",
            title: "Fixes the Insights-tab crash, plus more accurate HRV",
            date: "June 2026",
            items: [
                "Fixed (Android): the Insights tab crashed for anyone with journal entries — a text-matching pattern used a flag that works on a computer but not on Android’s engine, so it threw the moment you opened Insights. Fixed. Thanks @pilleuspulcher-blip and @maddognik (#224/#267).",
                "New (Android): if NOOP ever crashes, the details are now saved into the strap log you share — so a crash that only happens on your device can actually be diagnosed (#33).",
                "More accurate HRV: the heart-rate variability NOOP computes from a session now discards stray, irregular beats before averaging — the same cleaning the rest of its HRV maths already does — so a noisy WHOOP 5/MG optical reading no longer comes out inflated. Thanks @frazzle28 (#262/#235).",
                "Fixed (Mac): the sidebar and the Settings strap card could disagree about your connection — one saying ‘Connecting…’ while the other said ‘Connected’ for the same state. They now read from one source. Thanks @gingerbeardman (#266).",
                "Fixed (Mac & iPhone): the experimental WHOOP 5/MG deep-data unlock now requires the full encrypted bond. A live-HR-only link (strap still owned by the official app) can’t carry the unlock, so the button waits for a real bond and tells you to free the strap from the official app first. Thanks @Joshsil03 (#269).",
                "New (Android): the ‘Start a workout’ sport list now shows a scrollbar so you can tell it scrolls, and adds Tennis, Squash and Table tennis. Thanks @nhe (#265).",
                "New (Android & Mac): the Intelligence ‘By Day’ list gets a W / M / 3M / 6M / 1Y / ALL range filter to narrow to a recent window. Thanks @ujix (#252).",
                "New (Android): the Today heart-rate chart is now tap-and-drag interactive, matching iPhone and Mac. Thanks @ujix (#254).",
            ]),
        Release(
            version: "2.8.8",
            title: "Better strap-log diagnostics",
            date: "June 2026",
            items: [
                "Improved: shared strap logs now record which historical data layout your strap uses, and the Bluetooth signal strength at connect — invisible day-to-day, but it makes diagnosing a sync issue from a shared log much faster. Thanks @ryanbr. (#241)",
            ]),
        Release(
            version: "2.8.7",
            title: "Readiness shows its evidence, and a Health Connect distance fix",
            date: "June 2026",
            items: [
                "New: each Readiness signal now shows the numbers behind it — e.g. ‘HRV 72 vs 60 ms’, ‘Resting HR 46 vs 52 bpm’, ‘Training load 7d 10.0 / 28d 10.0’ — so you can see exactly why a signal is flagged, not just the label. Thanks @khalilkm01.",
                "Fixed (Android): a workout imported from Health Connect could show no distance even when the distance was recorded — a relay app (e.g. Suunto via Health Sync) often writes the distance with timestamps slightly offset from the workout, which NOOP's exact-window match missed. It now matches with a tolerance. Thanks @pilleuspulcher-blip. (#215)",
                "Fixed (iPhone): on the Explore screen, tapping a metric could bounce you back to the More tab instead of opening it — a nested-navigation bug. Drilling into a metric now works. Thanks @sebastianwoo. (#199)",
            ]),
        Release(
            version: "2.8.6",
            title: "iPhone diagnostics & expectations, clearer labels, a journal fix",
            date: "June 2026",
            items: [
                "New (iPhone): a 'Using NOOP on iPhone' note in Settings sets honest expectations — sideloading, re-signing, unlocking your phone after a reboot so history can sync — and shows how many days until your sideloaded build expires. The strap log you share now also carries the iPhone details (iOS version, lock state, background-refresh, low-power) that make iPhone-only issues quick to diagnose, with a one-tap Diagnostics screen to copy them.",
                "Fixed: copy that said 'this Mac' now reads correctly on iPhone. Thanks @robin-liquidium (#225).",
                "Fixed: the journal could show the same prompt (e.g. magnesium) twice after importing — duplicates are now merged, on every platform. Thanks @maddognik (#224).",
                "Improved (WHOOP 5/MG): the heart rate NOOP derives from the optical sensor on sleeping (sub-60 bpm) stretches no longer risks snapping to ~60 bpm from a recording artifact, while a genuine 60 bpm is preserved. Thanks @ryanbr (#194).",
            ]),
        Release(
            version: "2.8.5",
            title: "Fixed: iPhone import, and a stuck store now self-heals",
            date: "June 2026",
            items: [
                "Fixed (iPhone): importing a WHOOP or Apple Health export could silently do nothing — iOS was handing the app an iCloud file that hadn't downloaded yet. NOOP now downloads a local copy first (through the system Files picker), so imports actually go through. Thanks @adrnxq and @Chopin85. (#179)",
                "Fixed (iPhone): if a NOOP backup from another platform had been restored (e.g. an Android backup onto an iPhone), the app could get permanently stuck on “store not ready” — the imported database held the data but not the bookkeeping NOOP's database engine needs. NOOP now recovers automatically on the next launch, and declines such a backup at import time with a clear explanation. To move history across platforms, use the WHOOP-format CSV export instead. Thanks @NoahMcE. (#222)",
            ]),
        Release(
            version: "2.8.4",
            title: "New: a guide to how your Charge, Effort and Rest scores work",
            date: "June 2026",
            items: [
                "New: a clear in-app guide to how NOOP's three daily scores — Charge, Effort and Rest — are calculated, and how they differ from WHOOP's Recovery, Strain and Sleep. Tap the ⓘ on any score on the Today screen, or open it any time from Settings → About → How your scores work. New here? A one-time card points you to it.",
                "New: each score now explains how sure NOOP is of it — Solid, Building or Calibrating — and carries a one-line description of what it measures.",
            ]),
        Release(
            version: "2.8.3",
            title: "Fixed: imported data and strap sync getting stuck on iOS",
            date: "June 2026",
            items: [
                "Fixed (iOS): after importing your data, the strap could get stuck on \"store not ready\" and never sync — imported history wouldn't appear and backfill never started. On iOS the local database was sealed behind the device's data protection while the phone was locked, so a background reconnect couldn't open it (macOS and Android were never affected). NOOP now stores its database at the right protection level — readable after you first unlock since boot, still encrypted at rest — and retries automatically, so sync proceeds. Thanks @NoahMcE (#222).",
                "Improved: store-open failures are now written to the strap log with the real reason instead of failing silently, so problems like this are diagnosable at a glance.",
            ]),
        Release(
            version: "2.8.2",
            title: "Cross-platform parity — Android now scores identically to macOS & iOS",
            date: "June 2026",
            items: [
                "Fixed (Android): your Charge could read slightly low on Android because the skin-temperature term was weighted twice as hard as on macOS/iOS. All three apps now compute Charge identically. (#219)",
                "Fixed (Android, WHOOP 5/MG): the heart rate NOOP derives from the optical (PPG) sensor on stretches with no measured HR now uses the same harmonic-rejecting estimator as macOS/iOS — it could previously lock onto half or double your true rate — and it now also recovers HR from short data runs the way the other apps do. (#219)",
                "Fixed (Android): the respiratory-rate early-illness signal in Readiness now uses the same sensitivity thresholds and plausible-range filter as macOS/iOS, so all three apps flag it the same way.",
                "Fixed: assorted smaller cross-platform tidy-ups — skin-temperature data is now kept over the same range on every platform (Android was dropping valid just-put-on readings), CSV exports round-trip byte-for-byte, and a couple of score-rounding edge cases now agree across apps.",
            ]),
        Release(
            version: "2.8.1",
            title: "Battery + responsiveness: smarter sync, lighter notification",
            date: "June 2026",
            items: [
                "Improved (battery): NOOP now backs off its history-sync polling when the strap keeps handing over nothing (off-wrist or not yet banking) instead of re-trying every 90 seconds — a manual or reconnect sync still runs instantly, and the first real record resumes normal cadence. Thanks @ryanbr (#217).",
                "Improved: a just-synced night's Charge / Effort / Rest now appear the moment the sync finishes, instead of up to 15 minutes later. Thanks @FrostDev7 (#218).",
                "Improved (Android, battery): the persistent notification no longer re-draws with your live heart rate every second — it updates only when the connection, sync, recovery or battery state changes, cutting a constant background wakeup. Thanks @Eph00n and @spasypaddy (#216).",
            ]),
        Release(
            version: "2.8.0",
            title: "New: Week in review, a live body console, fresher charts and more",
            date: "June 2026",
            items: [
                "New: a **Week in review** — a deterministic, offline weekly digest of your Charge / Effort / Rest, HRV and resting HR, with week-over-week and vs-baseline changes and a plain-English read. It appears at the top of Trends once the week has a day or two of data. Thanks @subscriptiondestroyer (#208).",
                "New (Live screen): a live **body console** — a clearer at-a-glance readout of heart rate, recent R-R, a rolling RMSSD and the live connection/signal state. Thanks @khalilkm01.",
                "New: the Live heart-rate chart now has a **time axis** so you can read what window it covers and watch it scroll. Thanks @sebastianwoo (#198).",
                "Improved: charts and metrics now resolve the **freshest source** for each value (imported WHOOP, then NOOP-computed, then compatible Apple Health), so a screen never looks stale when newer data exists. Thanks @khalilkm01.",
                "New (Insights): a **personal experiments** (n-of-1) section that correlates a behaviour you log against your recovery — only for behaviours you actually have data for. Thanks @khalilkm01.",
                "Improved (AI Coach): when a local LLM truncates the conversation to fit its context window, NOOP now tells you, and caps the history it sends to local servers. Thanks @witchykinkajou.",
                "Improved (Android): the Today and Trends charts now have proper time and value axis labels. Thanks @ujix.",
            ]),
        Release(
            version: "2.7.0",
            title: "Big fix wave — clock, reconnect, local LLM, Explore, weight and more",
            date: "June 2026",
            items: [
                "Fixed (WHOOP 4.0): some straps on firmware 41.17.x silently failed to set their clock, so they banked no history and showed no sleep or recovery. NOOP now sends both clock-command formats, so these straps clock and bank correctly. Thanks @rad182 (#120).",
                "Fixed: the strap sometimes wouldn't reconnect after an app update — NOOP now rotates the scan between WHOOP 4 and 5/MG so it finds your strap either way. Thanks @khalilkm01.",
                "Fixed (AI Coach): the Custom provider can now reach a local LLM on your home network (e.g. Ollama at http://192.168.x.x:11434), not just localhost — on Android and iPhone, while cloud providers stay HTTPS-only. Thanks @andreasc1 (#187).",
                "Fixed (iPhone): the Backup buttons (Export / Import / Export CSV) no longer truncate to Ex / Im / E. (#188)",
                "Fixed: the Explore page was empty for WHOOP 5 users on live Bluetooth with no import — it now reads your computed daily scores. Thanks @sebastianwoo (#199).",
                "Fixed: the Today Weight tile now shows the weight you set in Settings when Apple Health has none. Thanks @subscriptiondestroyer (#204).",
                "Fixed (Android): imported Health Connect workouts now carry distance, so the Total Distance tile is no longer always zero. Thanks @pilleuspulcher (#215).",
                "Fixed (WHOOP 5/MG): PPG-derived heart rate now feeds the daily scores, so a night recorded only from the optical sensor can still be scored. Thanks @khalilkm01 (#212).",
                "Fixed (WHOOP 4.0): when a strap hands over an empty history sync, NOOP now reliably tells you to charge it to 100% and reconnect instead of silently showing nothing. Thanks @alberba (#214).",
                "Fixed (Mac): the on-device store now stays in the app's sandbox container, with a one-time migration so nothing is lost. Thanks @khalilkm01.",
            ]),
        Release(
            version: "2.6.10",
            title: "WHOOP 5/MG deep data: live confirmation it's working",
            date: "June 2026",
            items: [
                "New (iPhone and Android, experimental): the WHOOP 5/MG deep-data (R22) section now shows live confirmation of what the strap is doing — \"strap accepted 15/15 R22 flags\" the moment you send the enable sequence, and a count of deep packets if the strap starts streaming them. So you can see whether it's working without reading a log. A real 5/MG accepting the full sequence is now hardware-confirmed (#174) — the remaining step is seeing the deep packets actually flow, and this makes that obvious the instant it happens.",
            ]),
        Release(
            version: "2.6.9",
            title: "iPhone polish: What's New fits, Today cards align",
            date: "June 2026",
            items: [
                "Fixed (iPhone): the What's New screen shown after an update was sized for a desktop window, so it ran off the edges of the phone — you couldn't read the notes or reach the Got it button. It now fits the screen. Thanks @sebastianwoo (#185).",
                "Fixed (iPhone): in Today's Synthesis, the Charge read-out card is now the same height as the ring card beside it, so the two line up instead of leaving a gap. Thanks @sebastianwoo (#186).",
            ]),
        Release(
            version: "2.6.8",
            title: "iPhone import: handle iCloud and large export files",
            date: "June 2026",
            items: [
                "Fixed (iPhone): importing a WHOOP or Apple Health export could still fail right after you picked the file. NOOP now copies the file out of iCloud Drive / Files into local storage first — so a not-yet-downloaded iCloud file or a very large export actually opens — and then imports it. Thanks @adrnxq and @Chopin85 (#179).",
            ]),
        Release(
            version: "2.6.7",
            title: "More-tab icons stop flickering colour",
            date: "June 2026",
            items: [
                "Fixed (iPhone): the icons on the More tab briefly flashed from green to blue a second after the screen opened. They now stay the app's accent green. Thanks @sebastianwoo (#184).",
            ]),
        Release(
            version: "2.6.6",
            title: "iPhone Workouts table fits the screen",
            date: "June 2026",
            items: [
                "Fixed (iPhone): the Workouts → All Sessions table ran off the side of the screen, clipping the Sport, distance and source columns. It now scrolls sideways so every column is reachable, with a hint that you press-and-hold a workout to re-label, edit or delete it. Thanks @sebastianwoo (#183).",
            ]),
        Release(
            version: "2.6.5",
            title: "Broadcast your heart rate to Garmin, Zwift and gym kit",
            date: "June 2026",
            items: [
                "New (iPhone and Android, experimental): Broadcast heart rate — your WHOOP 5.0/MG can now advertise its heart rate as a standard Bluetooth HR sensor, so a Garmin (Edge or watch), Zwift, Peloton or a gym machine can read it directly during a workout. Turn it on under Settings → Experimental; it's opt-in and reversible, applied each time the strap connects. WHOOP 5.0/MG only (a Mac can't write to a 5/MG). Thanks @mornepousse (#181).",
            ]),
        Release(
            version: "2.6.4",
            title: "Tidier workout names, correct Rest duration",
            date: "June 2026",
            items: [
                "Fixed: workout names from your strap now read as proper words — Traditional Strength Training instead of TraditionalStrengthTraining — on the Today tiles, the Workouts breakdown cards and the session list, on all platforms. Thanks @RichrdJ (#175).",
                "Fixed: the Intelligence tab's Rest duration could read an hour too high (a 5h 39m night showed as 6h 39m) because the hours were rounded up instead of truncated. It now matches the Sleep tab and dashboard exactly. Thanks @FrostDev7 (#180).",
            ]),
        Release(
            version: "2.6.3",
            title: "Universal Mac build + iPhone import fix",
            date: "June 2026",
            items: [
                "Fixed (Mac): the download was accidentally an Apple-Silicon-only build, so it could not launch on Intel Macs at all. It now ships as a true universal binary that runs natively on both Intel and Apple Silicon. Thanks @stnnnts (#177, #165).",
                "Fixed (iPhone): importing a WHOOP export or Apple Health .zip on a sideloaded build — the file picker was greying out the .zip so nothing could be selected. iOS now offers only the file types it can actually open, so the .zip is selectable again. Thanks @adrnxq (#179).",
                "New (iPhone): an AltStore / SideStore source for one-tap updates on sideloaded installs — add https://raw.githubusercontent.com/NoopApp/noop/main/altstore-source.json as a source in AltStore or SideStore. Reimplemented from @RazvanRex (#178).",
            ]),
        Release(
            version: "2.6.2",
            title: "iPhone button-label polish",
            date: "June 2026",
            items: [
                "Fixed (iPhone): action buttons that were wrapping mid-word on a narrow screen — the Live screen's Re-scan / Buzz strap / Disconnect row and the Backup Export / Import / Export CSV row now keep each label on one line, shrinking to fit instead of breaking to one character per line. Thanks @marceauboul (#175).",
            ]),
        Release(
            version: "2.6.1",
            title: "Effort scale fix for imported data",
            date: "June 2026",
            items: [
                "Fixed: imported WHOOP Day Strain and workout strain now correctly land on NOOP's 0-100 Effort axis (the 0-21 to 0-100 rescale was defined in v2.6.0 but not wired up), so imported and on-device Effort finally share one scale. And NOOP's own CSV export now writes Effort on WHOOP's 0-21 scale, so re-importing your own export round-trips losslessly.",
            ]),
        Release(
            version: "2.6.0",
            title: "Charge, Effort & Rest — NOOP's own scores, out of 100",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android): NOOP now has its own daily scores, all out of 100 — Charge (how recovered and ready you are), Effort (the day cardiovascular + movement load), and Rest (last night sleep quality). They are computed on-device across WHOOP 4.0 and 5.0/MG from published sports-science methods (no WHOOP cloud): Charge folds HRV, resting heart rate, respiration, your skin-temperature deviation and Rest into one readiness number; Effort is your cardiovascular load curve; Rest weighs how long you slept versus your need, efficiency, restorative (deep + REM) sleep and consistency. Renamed from Recovery/Strain/Sleep and rescaled so everything reads on the same 0-100 axis. Imported WHOOP history is rescaled to match. They are honest approximations, not WHOOP scores.",
            ]),
        Release(
            version: "2.5.0",
            title: "Experimental: unlocking WHOOP 5.0/MG deep data",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android, experimental): a WHOOP 5.0/MG \"deep data\" unlock under Settings → Experimental. 5/MG straps give a fresh third-party app only live heart rate; the official app switches on the deeper streams by writing a set of feature flags. NOOP can now send that exact, documented sequence to your strap (opt-in, one button, only when worn + bonded). It writes to the strap but is reversible — it just changes which data the strap emits — and it is the same thing the official app does. Experimental: it may do nothing on your firmware yet. If you have a 5/MG, turning it on and sharing your strap log is exactly what we need to finish 5.0/MG support. iPhone/Android only (a Mac cannot write to a 5/MG). Built on the public protocol work of judes.club, Asherlc/dofek and b-nnett/goose. (#174)",
            ]),
        Release(
            version: "2.4.0",
            title: "A small, honest ask",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android): a small card on the Today screen — at most once every 12 hours — asking whether NOOP is proving useful, with the honest numbers: a WHOOP membership runs $300–480 a year, NOOP is free, and 5,000+ downloads in, 7 people have donated. \"Later\" snoozes it 12 hours; \"Don't ask again\" turns it off forever. It's a card in the flow, never a pop-over, and the stats are baked in at release time — the app still never touches the network.",
            ]),
        Release(
            version: "2.3.2",
            title: "Split sleep: every block counted, one night per day",
            date: "June 2026",
            items: [
                "Fixed (Mac and iOS): on a Bluetooth-only setup (no import), a day recorded as multiple sleep blocks showed only one block — the others were silently hidden. All blocks are now read from both sources, and a split day reads as ONE night: totals summed, the gap between blocks preserved in the hypnogram, and the \"N nights ago\" label counts days, not blocks. A night crossing midnight shows its span (e.g. \"Fri 13 → Sat 14 Jun\"). Implemented from PR #173 — thanks @FrostDev7. Android equivalent follows shortly (its day totals were already correct).",
            ]),
        Release(
            version: "2.3.1",
            title: "Skin temperature unblocked on Mac/iOS, plus export fixes",
            date: "June 2026",
            items: [
                "Fixed (Mac and iOS): skin temperature from the strap was being read on the wrong scale, which made every real night look impossibly cold and silently discarded it — so the nightly skin-temp deviation never appeared. Real nights now read correctly (matching Android), and your deviation builds after a few nights of wear. (#166, PR #97 review — thanks @tigercraft4)",
                "Fixed (Mac and iOS): the strap log no longer prints a stale \"layout v25/v26 … doesn't decode yet\" warning for layouts NOOP has decoded for a while. (#156, thanks @sudden-break)",
                "Fixed (all platforms): the CSV export wrote the sleep-disturbance count into the \"Awake duration (min)\" column — the cell is now left empty rather than carrying the wrong unit. Also: workouts present as both an import and an on-device detection are no longer exported twice, free-text fields are guarded against spreadsheet formula injection, and a failed export on macOS can no longer destroy your previous export file. (PR #97 review — thanks @tigercraft4)",
            ]),
        Release(
            version: "2.3.0",
            title: "HR from the optical waveform, an early-morning day rollover, and clearer terms",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android): on WHOOP 5.0/MG, NOOP now derives a per-second heart rate from the strap's optical (PPG) waveform to fill gaps where a stored HR isn't available. It's heart-rate continuity only — it does not reconstruct HRV — and a measured HR always takes priority over a derived one. (#156, thanks @j0b-dev)",
                "Fixed (Mac, iOS and Android): your day now rolls over in the early morning (~4am) instead of at midnight, so a late-night workout or a 1am glance still counts toward the right day rather than resetting underneath you. (#144)",
                "Improved (Mac, iOS and Android): nights with more than one sleep block (naps, split sleep) are now grouped by day, so each block is shown and navigated correctly. (#160)",
                "New (Android): an \"All other apps\" toggle under Notifications → Behaviour now buzzes your wrist for any app that isn't in the curated list (e.g. BeReal). Opt-in and off by default; quiet hours and only-when-worn still apply. (#168)",
                "Fixed (Mac): the Today heart-rate trend chart no longer bleeds its gradient down the page behind the cards beneath it.",
                "Updated terms (v1.1): added plain-English, explicitly non-clinical notes for the Mind mood check-in, nutrition import, and the iOS \"Export for Shortcuts\" path. You'll be asked to re-acknowledge once on first launch.",
            ]),
        Release(
            version: "2.2.1",
            title: "Shortcuts-export duplicates fixed; nutrition & mood reach Android charts",
            date: "June 2026",
            items: [
                "Fixed (iOS): the \"Export for Shortcuts\" file is now truncated when there's nothing new, so a Shortcut automation firing on every app close can't re-import the previous rows into Apple Health — exports are strictly differential. (#167, thanks @alexsas00)",
                "Fixed (Android): imported nutrition (calories-in, protein, carbs, fat) and your Mood series now appear in Explore and Compare with proper names and units — they were stored but invisible to the metric pickers.",
            ]),
        Release(
            version: "2.2.0",
            title: "Mind — a daily mood check-in — and nutrition import",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android): Mind — a one-tap daily mood check-in (five faces) on the Insights screen. Over time it shows, privately and on-device, how your mood tracks with your HRV, sleep and recovery (e.g. \"on days your HRV is higher, your mood averages higher\"). It's self-tracking, not a clinical assessment — and nothing leaves your device.",
                "New (Mac, iOS and Android): import a nutrition CSV (Cronometer, MacroFactor, or a generic export) — your daily calories-in, protein, carbs and fat land alongside your strain and recovery in Explore and Compare, so you can finally see calories-in next to calories-out. Offline, file-based, optional.",
            ]),
        Release(
            version: "2.1.0",
            title: "Browse past nights, smarter Coach, workout times, battery & more",
            date: "June 2026",
            items: [
                "New (Mac, iOS and Android): the Sleep screen now lets you browse past nights — tap ◀/▶ on the hypnogram to step back through every recorded night, not just last night. (#160, thanks @FrostDev7)",
                "Fixed (Android): the AI Coach now sees the recovery, strain, sleep and HRV that NOOP computes on-device for live-strap users — it was only reading imported rows, so a Bluetooth-only user's Coach wrongly said it had no data. (#124)",
                "Fixed (Android): your imported step count now updates for TODAY, not just past days — NOOP refreshes today's Health Connect steps when you open the app. (#150)",
                "New (Mac, iOS and Android): workouts now show their start–end time (e.g. 13:00–13:30), and the Today screen shows your strap's battery level. (#157, #159)",
                "New (Mac, iOS and Android): a Step calibration setting — if your step count runs high on a WHOOP 5.0/MG, set how many motion-counter ticks equal one real step (the default leaves counts unchanged). (#139)",
                "New (Mac, iOS and Android): Breathe sessions now show your HRV response — how much your RMSSD rose from start to finish, and the peak — so you can see the calming effect land.",
                "New (iOS): an opt-in \"Export for Shortcuts\" that writes your heart rate, HRV and steps to a file an Apple Shortcut can log into Apple Health — a HealthKit-free path for sideloaded installs. (#155, thanks @alexsas00)",
                "Hardened (Mac, iOS and Android): the archived-sleep retro-decode now retries on the next launch if a save fails midway, instead of giving up — so recovered history is never lost to a transient error. (#152, thanks @ryanbr)",
            ]),
        Release(
            version: "2.0",
            title: "Clearer answers when your strap isn't banking history",
            date: "June 2026",
            items: [
                "Improved (Mac, iOS and Android): your strap log now records what a sync SAVED, not only what failed — a \"persisted N rows (M with motion) across K night(s)\" line on every successful offload. NOOP previously logged only failures, so a shared log couldn't show whether history was actually banking; now it can. (#150)",
                "Improved (Mac, iOS and Android): when the strap reports it has no stored history to hand over (its \"no flash cursor\" state), NOOP now names the real cause plainly — the strap's clock has lost sync and it isn't saving to flash, a charge/clock state on the strap, NOT a NOOP decode bug. The Troubleshooting and FAQ guides now lead with this, the most common reason recovery and sleep don't appear, with the fix: fully charge to 100% and reconnect. (#150)",
            ]),
        Release(
            version: "1.99",
            title: "Your imported steps now show on the Today screen (Android)",
            date: "June 2026",
            items: [
                "New (Android): the Today screen's Steps tile now shows the steps from your Apple Health / Health Connect import when the strap didn't bank an on-device count — so a WHOOP 4.0, which NOOP can't yet read steps off over Bluetooth, shows your imported steps instead of \"No Data\" (Mac and iOS already did this). Worth saying plainly: the WHOOP 4.0 does count steps in the official WHOOP app — the only gap was that NOOP couldn't surface them yet. (#150)",
            ]),
        Release(
            version: "1.98",
            title: "The archived-sleep recovery now reaches Android too",
            date: "June 2026",
            items: [
                "Recovered (Android): the reject-archive retro-decode that landed on Mac & iOS in v1.97 now runs on **Android** as well. If your WHOOP 4.0 on Android synced \"v25\" firmware records before v1.95 — when NOOP couldn't read that layout — that sleep and recovery were saved but left dark; on update NOOP now re-runs them through the current decoder and backfills those nights. (#151)",
            ]),
        Release(
            version: "1.97",
            title: "Sleep that was stuck in the archive comes back",
            date: "June 2026",
            items: [
                "Recovered (Mac, iOS and Android): if your WHOOP 4.0 synced \"v25\" firmware records *before* v1.95 — when NOOP couldn't read that layout yet — those records were saved to NOOP's on-device archive but left dark, and the strap had already freed them. NOOP now re-runs that archive through the current decoder on update, so your sleep and recovery from those nights backfill. It happens once per decoder upgrade, automatically. (#151)",
                "Fixed (Mac, iOS and Android): the AI Coach now formats its replies properly — **bold**, bullet/numbered lists and headings render, instead of showing as raw Markdown symbols. (#149)",
            ]),
        Release(
            version: "1.96",
            title: "iOS is now a direct download — no Mac or Xcode needed",
            date: "June 2026",
            items: [
                "New: the iOS app is now a **direct download** you install with AltStore or SideStore — it signs on your own iPhone with your own free Apple ID, so there's no App Store, no developer account, and NOOP stays anonymous. You no longer need a Mac and Xcode to run it. (Two notes, stated plainly: a free Apple ID re-signs the app every 7 days — AltStore automates that — and some Apple-only integrations like Apple Health and Live Activity widgets can be limited under a free signing identity.)",
                "Fixed (Mac, iOS and Android): the \"your strap's clock has lost sync\" warning no longer appears after a single quiet sync. It now waits for several empty syncs in a row before warning, so a healthy strap that simply had nothing new to hand over one cycle doesn't get a false alarm. (#126)",
                "Fixed (Android): Health Connect import now respects partial permissions — switch off the data types you don't want NOOP to read, and it imports the rest instead of refusing the whole import. (#150)",
            ]),
        Release(
            version: "1.95",
            title: "Sleep and recovery for WHOOP 4.0 straps on the firmware we couldn't read",
            date: "June 2026",
            items: [
                "New (Mac and Android): some WHOOP 4.0 straps run a firmware whose offloaded history NOOP couldn't decode for motion — so sleep and recovery never built from the strap, even though live heart rate worked. NOOP now reads that firmware's motion (the accelerometer gravity vector) and per-second timestamps, which is exactly what the sleep engine needs. Once your strap banks a night, sleep staging and recovery can finally build from it. Heart rate in this layout is derived from the optical sensor rather than stored second-by-second, so this unlock is specifically the motion data. (#30)",
            ]),
        Release(
            version: "1.94",
            title: "Manual workouts on WHOOP 5.0/MG get their calories and strain back",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): a workout you start yourself now fills in its calories, average heart rate and strain even on a WHOOP 5.0/MG. The live heart-rate stream on 5/MG is sparse, so a manual session was often saved showing ~1 kcal and no strain — now, once your strap offloads the heart rate it banked during the session, NOOP re-scores that workout from the fuller data. Well-scored workouts are left untouched. (#137)",
            ]),
        Release(
            version: "1.93",
            title: "Tidy your journal — remove and hide questions",
            date: "June 2026",
            items: [
                "New (Mac and Android): the Journal now has an Edit mode (tap Edit on the Journal card) to curate your questions. Delete custom questions you've added, and hide any built-in ones you don't use — hidden questions are listed under the card and can be restored anytime. (#140)",
            ]),
        Release(
            version: "1.92",
            title: "Better diagnostics for newer strap firmware — so we can decode it",
            date: "June 2026",
            items: [
                "Improved (Mac and Android): when your strap's historical records use a firmware layout NOOP can't decode yet — newer WHOOP 5.0/MG units, and some WHOOP 4.0 straps, which is why sleep, recovery and steps can be missing (see #30, #136) — the strap log now includes the full record bytes (it previously cut them off after 64) plus a few more sample records. That's exactly what we need to map the new layout, so a single fresh strap log from an affected device now carries everything required for us to add support.",
            ]),
        Release(
            version: "1.91",
            title: "Run the AI Coach on your own model — including fully local",
            date: "June 2026",
            items: [
                "New (Mac and Android): the AI Coach can now talk to any OpenAI-compatible server — including a model running locally on your own machine (Ollama, LM Studio, llama.cpp). Pick \"Custom (OpenAI-compatible)\", point it at your server URL (e.g. http://localhost:11434/v1) and choose a model; an API key is optional. With a local model, your coaching conversation and metrics never leave your device. (#131)",
            ]),
        Release(
            version: "1.90",
            title: "NOOP now tells you when your strap isn't saving history — and how to fix it",
            date: "June 2026",
            items: [
                "Improved (Mac and Android): when a sync completes but your strap handed over only its diagnostic output and no stored history — which means its clock has lost sync and it isn't saving data to flash — NOOP now says so, with the fix (fully charge the strap to 100%, then reconnect), instead of silently reporting \"synced.\" It's the single most common reason recovery, sleep and strain stop appearing on a WHOOP 4.0, and it's now told apart from a normal caught-up sync. (#77, #91, #120)",
            ]),
        Release(
            version: "1.89",
            title: "Live heart rate lands on today's chart even when the strap's clock is off (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): if your WHOOP's internal clock was invalid (the same condition that can stop it banking history), live heart rate still streamed and was saved — but it got stamped with the strap's bogus clock, so it landed off-today and the Today 24-hour HR trend read empty even though live HR was working. Live readings are now anchored to your phone's clock as they arrive, so they always land on today's timeline. (#126)",
            ]),
        Release(
            version: "1.88",
            title: "Smoother Explore charts, and a clearer way to connect a WHOOP 5.0/MG",
            date: "June 2026",
            items: [
                "Fixed (Mac): the Explore chart no longer flickers or re-animates its line when you move the cursor across a card. The v1.77 fix caught one cause; a second remained — the card surface was animating its hover transition over its whole contents, the chart included — now scoped to just the card's border and shadow. (#104)",
                "Improved (Mac and Android): connecting a WHOOP 5.0/MG is clearer. macOS first-run setup now asks you to pick your strap model first instead of defaulting to a WHOOP 4.0 scan, and selecting WHOOP 5.0/MG (both platforms) shows an inline note that it pairs with one app at a time — so if a scan finds nothing, free it in the official WHOOP app and try again. (#130)",
            ]),
        Release(
            version: "1.87",
            title: "Deep sleep that happens later in the night no longer reads 0 minutes",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): a follow-on to the deep-sleep fix. NOOP assumes deep sleep is front-loaded (it usually is) and re-imposes that on the staging — but it was zeroing out ALL deep detected after the first third of the night, so nights where your deepest stretch lands later showed 0 minutes of deep even though the signature was there. It now only applies that rule when there's deep early in the night to anchor it; a later-deep night keeps its deep. Thanks to a very precise bug report. (#127)",
            ]),
        Release(
            version: "1.86",
            title: "Deep sleep no longer reads 0 minutes, and a smarter AI Coach",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): on-device sleep nights no longer show 0 minutes of deep sleep. Deep sleep required a per-epoch HRV reading, which is often sparse on Bluetooth-synced nights (especially WHOOP 5/MG), so it was getting blocked entirely. It now falls back to the other depth signals — stillness, low heart rate and regular breathing — when HRV isn't measurable that second, while still requiring genuinely high HRV when it is. (#127, #129)",
                "Improved (Mac and Android): the AI Coach now also sees your SpO₂, respiration, skin-temperature deviation, steps and active energy in its summary — it previously had only recovery, strain, sleep, HRV and resting HR. (#124)",
            ]),
        Release(
            version: "1.85",
            title: "Browse the last few days, interactive charts, and a Vital Signs screen (Android)",
            date: "June 2026",
            items: [
                "New (Android): browse the last 3 days on Today, Sleep and Vital Signs — flip between Today, Yesterday and 2 days ago from the same screen.",
                "New (Android): charts are now interactive on Sleep, Trends and the new Vital Signs detail — tap and swipe across the line to read off the exact value at any point.",
                "New (Android): Vital Signs is now a first-class screen reachable from the menu — your resting HR, HRV, SpO₂, skin temperature and respiratory rate with their recent history and context in one place.",
                "Improved (Android): more robust background reconnect — the long-lived connection and its persistent notification come back cleanly after an app update or restart. (A community contribution — thank you.) (Mac: version bump only.)",
            ]),
        Release(
            version: "1.84",
            title: "Fix the Android freeze after a few nights of data",
            date: "June 2026",
            items: [
                "Fixed (Android): the app could freeze and get killed (\"app isn't responding\") after a strap had banked a few nights of history. The nightly sleep analysis ran a slow scan ON the main thread; it's now off the main thread and the scan itself went from O(n²) to O(n) — so the app stays responsive no matter how much history accumulates. (Mac was never affected — it already ran this off-screen.) (#125, thanks to a detailed field report)",
                "Improved (Mac and Android): the strap log no longer reads a history chunk that's only the strap's own diagnostic chatter as \"dropped\" data, and it now logs undecodable records on partially-decoded chunks too — clearer when something genuinely needs attention. (#120, #123)",
            ]),
        Release(
            version: "1.83",
            title: "Workout calories — for manual sessions and Health Connect imports",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): a workout you start yourself now estimates its calories from your heart rate — the same model NOOP uses for auto-detected workouts — instead of leaving the field blank. (#117)",
                "Fixed (Android): workouts imported from Health Connect (e.g. Garmin) now show their calories. NOOP credits each session with the active calories burned inside its time window (a Health Connect exercise record carries no energy of its own, so this stitches them together). (#117)",
            ]),
        Release(
            version: "1.82",
            title: "Stop losing strap history we can't yet decode — plus a board of fixes",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): NOOP no longer destroys strap history it can't yet decode. If a history chunk arrived with a bad checksum or a firmware record layout we haven't mapped, NOOP used to tell the strap \"got it\" anyway — and the strap then freed (erased) that data while the screen said \"synced\". NOOP now archives those raw records on-device before acknowledging, and if it can't save them it leaves them on the strap to retry, so an unrecognised firmware can no longer cost you your data. (#77, #91)",
                "Fixed (Android): a Health Connect sync no longer blanks a strap-only day. With no WHOOP import, a sync could write a sparse day record that hid your on-device recovery/strain and regressed your sleep stages; Health Connect now only fills days your strap didn't already cover. Nothing was deleted — this restores it. (#112)",
                "Fixed (Android): the Today screen's Steps, Calories and Weight tiles now show real data instead of always reading \"no data\". Weight falls back to your profile figure when there's no measured reading. (#107)",
                "New (Mac): Google Gemini as a third bring-your-own-key AI Coach provider, alongside OpenAI and Anthropic.",
                "New (Mac): a clear \"Standard HR mode\" note when the radio falls back to low-bandwidth heart rate (#80); a guard that refuses an Android backup on Mac instead of overwriting your database; and imported Apple Health body-weight now actually shows up.",
            ]),
        Release(
            version: "1.81",
            title: "Start a workout from the Workouts screen, and an honest Smart-alarm note",
            date: "June 2026",
            items: [
                "New (Android): start a workout straight from the Workouts screen, not only from Live — the same sport picker and GPS toggle, with a compact running banner and an End button while one's in progress.",
                "Changed (Android): the Smart alarm now says plainly that it's experimental and that a WHOOP 5/MG only arms it when Experimental mode is on — so the wake time isn't silently saved against a strap that was never armed. Keep a backup alarm.",
            ]),
        Release(
            version: "1.80",
            title: "Journal logging + an Imperial/Metric units toggle",
            date: "June 2026",
            items: [
                "New (Mac and Android): log how you're living — a journal card on the Insights screen with quick yes/no chips for behaviours (caffeine, alcohol, a late meal, screen time, and your own custom questions). Your entries stay on-device and are never overwritten by an import.",
                "New (Mac and Android): an Imperial / Metric units toggle in Settings — distance (km / mi), weight (kg / lb), height (cm / ft-in) and temperature (°C / °F), with a separate temperature override. Everything stays stored the same; this only changes how it's shown.",
            ]),
        Release(
            version: "1.79",
            title: "Manual workouts, edit/dismiss auto-detected ones, and CSV export",
            date: "June 2026",
            items: [
                "New (Mac and Android): add a workout by hand, and edit, re-label, or dismiss the ones NOOP auto-detects — so a misread bout or a duplicate no longer sticks around with no way to remove it. Dismissals are remembered, so a re-detected session stays hidden.",
                "New (Mac and Android): export all your data as a WHOOP-format CSV bundle (cycles, sleeps, workouts, journal) from Settings — yours to keep, and it imports straight back into NOOP.",
            ]),
        Release(
            version: "1.78",
            title: "Fewer false daytime sleeps + an Android sync button",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): a long sedentary daytime stretch — at your desk, on the couch, in a long meeting — no longer gets logged as sleep. Daytime periods now need a longer, genuinely low-heart-rate window before they count, while overnight sleep and real naps are unchanged.",
                "New (Android): a manual “Sync now” button on the Live screen, plus an honest progress indicator while your strap’s history is offloading.",
            ]),
        Release(
            version: "1.77",
            title: "First-run terms acknowledgment + an Explore chart fix",
            date: "June 2026",
            items: [
                "New (Mac and Android): a one-time, plain-English terms acknowledgment on first launch — what NOOP is, that it's independent of WHOOP and that using it may breach WHOOP's Terms of Service, that it's not a medical device, and that you use it at your own risk. Standard for an independent, on-device tool — you accept once. The full terms ship in TERMS.md.",
                "Fixed (Mac): the Explore metric charts no longer flicker to a straight line when the cursor crosses into or out of the graph.",
            ]),
        Release(
            version: "1.76",
            title: "Robust Apple Health import, marginal-radio HR mode, live HR graph",
            date: "June 2026",
            items: [
                "Improved (Mac and Android): a very large Apple Health export no longer fails to import because of a single malformed byte. NOOP now skips the bad spans and imports everything else, and tells you how many it skipped — so multi-year exports that errored out before should come in fine now.",
                "New (Mac): if your Bluetooth radio can't sustain WHOOP 4's full realtime stream (older Macs, OpenCore setups), NOOP now automatically falls back to a low-bandwidth standard heart-rate mode — so live HR keeps working instead of the connection looping on a drop.",
                "Fixed (Mac): the Health tab's live heart-rate graph now builds a continuous trace over time, instead of getting stuck showing only two points.",
            ]),
        Release(
            version: "1.75",
            title: "Personal vital baselines + Mac analytics parity",
            date: "June 2026",
            items: [
                "New (Mac and Android): the Health Monitor now judges each vital — HRV, resting heart rate, respiratory rate, skin temperature — against YOUR own learned baseline (after about 14 nights), not just a one-size-fits-all population range. So a personal normal that happens to sit outside the textbook band — say a naturally lower HRV — stops reading as \"off\" when it's perfectly fine for you. Until your baseline is established it falls back to the typical range.",
                "New (Mac): macOS now computes steps, respiratory rate, daily calories and nightly skin temperature on-device, matching what Android already did — and nightly respiration now feeds into the recovery score on both platforms. Existing recoveries are unchanged when respiration isn't available.",
            ]),
        Release(
            version: "1.74",
            title: "Android reconnect guide + a startup-crash fix",
            date: "June 2026",
            items: [
                "Android now matches the Mac: if your WHOOP 5.0 / MG can't connect after a firmware update (a Bluetooth pairing reset), NOOP detects it and shows the forget-and-re-pair steps right in the app, instead of silently retrying. (Mac got this in 1.73.)",
                "Fixed (Android): a rare startup crash on some fast devices (e.g. Galaxy S24+) — the app could crash once on launch when a strap was already connected, then open fine on the second try. (Mac was never affected.)",
            ]),
        Release(
            version: "1.73",
            title: "Reconnect help for WHOOP 5.0 / MG after a firmware update",
            date: "June 2026",
            items: [
                "If your WHOOP 5.0 / MG stopped connecting after a WHOOP firmware update, that's a Bluetooth pairing reset — not a lockout, and NOOP works fine on the new firmware. To reconnect: quit the official WHOOP app, forget the strap in your Bluetooth settings, put it in pairing mode (tap the band until the LEDs flash blue), then reconnect. On Mac, NOOP now detects this automatically and shows you these exact steps in-app instead of silently retrying. WHOOP 4.0 is unaffected.",
            ]),
        Release(
            version: "1.72",
            title: "GPS workout crash fix (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): starting a GPS-tracked workout could crash the app on Android 12 and newer. GPS needs location permission, which NOOP never requested — and it was capped to older Android versions — so route tracking failed the instant it began. NOOP now asks for location permission right before a GPS workout and fails safe if it's unavailable: the workout still records heart rate and strain, just without a route. If you don't use GPS workouts, nothing changes. (Mac: version bump only.)",
            ]),
        Release(
            version: "1.71",
            title: "GPS-tracked workouts (Android)",
            date: "June 2026",
            items: [
                "New (Android): when you start a workout you now pick a sport (searchable), and your phone's GPS records the route, distance and pace as you go. Live distance + pace show on the workout card; at the end the route draws right on the Live screen — entirely offline, no maps are fetched. The session can also write to Health Connect (opt-in, under Data Sources). Builds on the manual workout tracking from v1.67. A community request. (Mac: version bump only.)",
            ]),
        Release(
            version: "1.70",
            title: "Clearer sync status + a responsive Compare screen",
            date: "June 2026",
            items: [
                "Improved (Android): the Live screen now says \"Syncing your strap history…\" plainly while the strap is offloading, so it's obvious it's working — the brief status-pill change was easy to miss. (Mac already showed this clearly.)",
                "Fixed (Mac): the Compare screen's time-range controls now stack instead of overflowing when the window is narrow.",
            ]),
        Release(
            version: "1.69",
            title: "Cleaner Live status + better sync diagnostics",
            date: "June 2026",
            items: [
                "Fixed (Mac and Android): the \"Last Event\" line on the Live screen no longer shows an internal name when live heart rate starts (it used to read \"BLE_REALTIME_HR…\"). It now only shows meaningful strap events — wrist on/off, double-tap, battery, and so on.",
                "Diagnostics (Mac and Android): when the strap sends history that NOOP can't decode, the strap log now prints a short hex sample of the dropped records — not just the count. If your WHOOP 4 is on a firmware whose record layout we haven't mapped yet (history syncs but no data appears), turning on Debug logging and sharing the strap log now gives us the exact bytes we need to add support. Chasing one of these now (#91).",
            ]),
        Release(
            version: "1.68",
            title: "Sleep figures, HR zones, charging & calibration — a big community-driven update",
            date: "June 2026",
            items: [
                "New (Mac and Android): your workouts now show an HR Zones card — time spent in each heart-rate zone for imported sessions, with a duration-weighted summary.",
                "New (Mac and Android): a \"· Charging\" indicator on the battery pill when your strap is on the charger.",
                "Improved (Mac and Android): sleep tiles now prefer WHOOP's own imported figures (sleep performance, consistency, need, debt) when available, falling back to NOOP's on-device estimate otherwise — and Android now imports those four figures too.",
                "New (Android): the sleep screen draws a real hypnogram from the per-epoch stages, not just a summary.",
                "New (Mac): recovery shows \"Calibrating — N of 4 nights\" while it learns your baseline, instead of a misleading empty ring.",
                "New (Mac): \"History synced N ago\" in Today and the menu bar, so you can see at a glance when your strap last offloaded.",
                "New (Mac): the illness early-warning can post a system notification when it first flags a day (opt-in, off by default, once per day); Android already did this.",
                "New (Mac): a firmware wake-up alarm for WHOOP 5/MG — experimental: arming is confirmed, but a strap-driven wake hasn't been verified yet, so don't rely on it as your only alarm there. WHOOP 4 is the proven path.",
                "Most of this release came from a generous community contribution — thank you.",
            ]),
        Release(
            version: "1.67",
            title: "Track a workout manually",
            date: "June 2026",
            items: [
                "New (Mac and Android): start and stop a workout yourself, instead of waiting for NOOP to detect one. Tap Start workout on the Live screen and you get a live card — elapsed time, heart rate, and strain building in real time; tap End and it's scored and saved to your Workouts, contributing to the day. Perfect for a session NOOP might not auto-detect, or when you just want a clean start/stop. Needs a connected strap streaming live heart rate. A community request — thanks for the nudge.",
            ]),
        Release(
            version: "1.66",
            title: "Android: WHOOP 4 on newer firmware now records data",
            date: "June 2026",
            items: [
                "Fixed (Android): a WHOOP 4.0 on a firmware version NOOP hadn't mapped recorded NOTHING — the history sync finished but every record was silently dropped, so heart rate, sleep and recovery all stayed empty. Mac already handled this (it falls back to the standard record layout for unknown firmware); Android didn't, so it dropped the data entirely. Android now does the same fallback, accepting an unmapped firmware's records only when they decode to physically-real data (so it can never store garbage). If your WHOOP 4 was syncing but showing no data, update and it should start filling in. Investigating exactly this on a Samsung report (#77). Mac: version bump only.",
            ]),
        Release(
            version: "1.65",
            title: "Sync diagnostics: surfacing silently-dropped history",
            date: "June 2026",
            items: [
                "Diagnostics (Mac and Android): if a chunk of history arrives from the strap but none of it can be decoded — frames failing their checksum, an unrecognised firmware layout, or out-of-range timestamps — NOOP now says so plainly in the strap log instead of quietly moving on. Until now a sync like that looked completely healthy (\"history synced\") while the data went nowhere, which made a rare \"I wore it but got no data\" report almost impossible to diagnose. This release changes no behaviour — it just makes that case visible — so if your history isn't showing up, turning on Debug logging and sharing your strap log will now point straight at the cause. Investigating a report along these lines (#77).",
            ]),
        Release(
            version: "1.64",
            title: "Android: faster sync, skin temp, sync status, alarm groundwork",
            date: "June 2026",
            items: [
                "New (Android): a batch of WHOOP 5/MG improvements, with thanks to a community contributor. Sync is faster and more reliable — NOOP now negotiates a larger Bluetooth packet size on connect, so a full history record rides one packet instead of being chopped into fragments. The Live screen now tells you the honest truth about syncing: \"History synced N ago,\" or a clear note if a sync stalled — no more silent guessing for a cloud-free app. Skin-temperature deviation now builds offline from the strap's own nights (wear-gated, in-bed only, baseline-seeded like recovery — APPROXIMATE), which also re-arms the illness early-warning signal. And the recovery ring now shows \"Calibrating — N of 4 nights\" while it learns your baseline, instead of a blank \"No Data.\" Also groundwork for a 5/MG firmware wake alarm — it's behind the Experimental toggle and UNCONFIRMED (help us verify it actually wakes you before relying on it). Mac: version bump only.",
            ]),
        Release(
            version: "1.63",
            title: "Mac: strap-computed nights show in Sleep",
            date: "June 2026",
            items: [
                "Fixed (Mac): nights computed from the strap alone were missing from the Sleep tab entirely — Intelligence scored them, but Sleep showed nothing (#77). The strap's on-device analysis stores its stage data in a different shape than a WHOOP import, and the Sleep tab only knew how to read the imported one. Bonus of the fix: Bluetooth-only nights now draw their REAL stage timeline in the hypnogram (imported nights still use an approximate reconstruction, since the export carries totals only). The usual honesty note applies: on-device stages are approximations from heart rate, HRV and movement — not PSG-validated. Android already handled both shapes; version bump only there.",
            ]),
        Release(
            version: "1.62",
            title: "WHOOP 5/MG history: the missing clock",
            date: "June 2026",
            items: [
                "New (Mac and Android, experimental): NOOP now sets the clock on a WHOOP 5.0/MG before asking for its history — and that matters more than it sounds: an un-clocked WHOOP 5 doesn't save sensor data at all, so history syncs were \"succeeding\" with nothing in them. A fellow developer's work on real 5/MG hardware found this (history went from 0 to hundreds of frames once clocked) along with several smaller protocol fixes NOOP now carries: the history request waits for the strap to acknowledge a range query first (with a retry if it stays silent), an Android 5/MG connects directly to the strap your phone already paired instead of re-scanning, fresh history is scored within seconds instead of at the next 15-minute tick, and the strap's own diagnostic messages now appear in the strap log. Also new (Android, opt-in, default OFF): \"Record 5/MG raw capture\" in Settings → Experimental writes each history sync's raw frames to a shareable file — if you have a 5/MG, sharing one capture is the single most useful thing you can do to help NOOP learn to decode 5/MG sleep, recovery and strain. With thanks to tajchert, whose hardware-validated fork drove this release.",
            ]),
        Release(
            version: "1.61",
            title: "Android: the widget now actually updates",
            date: "June 2026",
            items: [
                "Fixed (Android): the home-screen widget could freeze on \"—\" for heart rate and battery while the app itself streamed live HR perfectly well (#82, second find). The widget update was being cancelled mid-write every time a new heart-rate sample arrived — and with samples landing every second, no update ever finished once streaming started. Updates now run to completion, and the first heart-rate sample after connecting shows on the widget immediately instead of waiting out a refresh window. Thanks to the reporter whose precise symptoms — live HR fine in the app, widget stuck with \"Connected\" underneath — pointed straight at it. Mac: version bump only.",
            ]),
        Release(
            version: "1.60",
            title: "Android: notification recovery fix + widget armour",
            date: "June 2026",
            items: [
                "Fixed (Android): the background notification now actually shows today's Recovery % — v1.56 announced it, but the value was computed and never drawn. Also: armour for the home-screen widget — if it ever fails to draw it shows a small fallback message and heals on its next update, the background notification now survives database hiccups instead of taking the connection down, and the widget's internal scheduler library was brought up to the current Android-14-era version. We investigated a reported \"app keeps stopping\" crash (#82) with a fresh-install reproduction on a clean Android 14 device and could not trigger it — if you ever see it, please report your device model and Android version. Mac: version bump only.",
            ]),
        Release(
            version: "1.59",
            title: "Android: share back to Health Connect",
            date: "June 2026",
            items: [
                "New (Android, opt-in): NOOP can now write the nightly metrics it computes from your strap — resting heart rate, HRV, SpO₂ and respiratory rate — into Health Connect, so other apps can use them. Off by default; flip \"Share back to Health Connect\" in Data Sources and grant the write permissions. Only NOOP's own computed values are written (imported data is never echoed back), and re-writes update in place rather than stacking duplicates. Mac: version bump only.",
            ]),
        Release(
            version: "1.58",
            title: "Android: bottom tab bar",
            date: "June 2026",
            items: [
                "New (Android): a bottom tab bar — Today, Trends, Live and Sleep are now one thumb-tap away, with a More tab that opens the full grouped list of screens. Nothing moved: the hamburger menu still works exactly as before, every screen is reachable from both, and your back button behaves the same. Mac: version bump only.",
            ]),
        Release(
            version: "1.57",
            title: "Android home-screen widget",
            date: "June 2026",
            items: [
                "New (Android): a home-screen widget. Today's recovery — coloured green, amber or red by the usual bands — plus live heart rate and strap battery, at a glance without opening the app. It updates from the background connection (or while the app is open), shows when it last heard from the strap, and tapping it opens NOOP. Long-press your home screen → Widgets → NOOP to add it. Honest-blank until NOOP has learned enough nights to score you. Mac: version bump only.",
            ]),
        Release(
            version: "1.56",
            title: "Shortcuts on Mac, recovery in the Android notification",
            date: "June 2026",
            items: [
                "New (Mac): NOOP now offers two Shortcuts actions — \"Buzz Strap\" and \"Mark a Moment\" — so you can vibrate your connected strap or drop a timestamped marker from Shortcuts, Spotlight, or a menu-bar/keyboard trigger without opening the app's window. They act on the strap NOOP is already bonded to; if NOOP isn't running, or the strap isn't connected, you get a clear \"open NOOP\" / \"connect your strap\" message instead of a silent no-op. No new permissions — just the strap you already paired.",
                "New (Android): the ongoing background notification now shows today's recovery % alongside live heart rate and strap battery, so a glance at your shade tells you how recovered you are without opening the app. It updates itself when the on-device analysis recomputes (about every 15 minutes), and stays absent until NOOP has learned enough nights to score you honestly.",
            ]),
        Release(
            version: "1.55",
            title: "Mac: recovery builds from your strap alone",
            date: "June 2026",
            items: [
                "New (Mac): recovery now builds from the strap's own offloaded nights, no WHOOP export needed — the same fix Android got in v1.53. The recovery baseline previously only learned from imported history, so a Bluetooth-only Mac user never crossed the \"learn your baseline\" threshold and recovery stayed blank. NOOP now seeds the baseline from the nights it computes on-device too, so after about four nights recovery lights up on its own. Honest-blank until then; a real import still wins per day. Also: the WHOOP 5.0/MG step counter now persists on Mac (parity with Android — surfaced later, still APPROXIMATE). Android: version bump only (it already had both).",
            ]),
        Release(
            version: "1.54",
            title: "French WHOOP exports now import",
            date: "June 2026",
            items: [
                "Fixed: French WHOOP CSV exports now import. Like German and Spanish before it, a French export translates both the column headers (Score de récupération, Variabilité de la fréquence cardiaque, …) and the sleep/workout filenames (sommeil.csv, entrainements.csv), so it used to match nothing and reported \"0 items.\" NOOP now maps every French column — including the full workout set with HR zones — and recognises the French filenames, so recovery, strain, sleep, HRV and workouts all import. Mac and Android. Thanks to a reporter who supplied a real export's headers (#79).",
            ]),
        Release(
            version: "1.53",
            title: "Recovery builds from your strap alone (Android)",
            date: "June 2026",
            items: [
                "New (Android): recovery now builds from the strap's own offloaded nights — no WHOOP export needed. Before, the recovery baseline only ever learned from imported history, so a Bluetooth-only user never crossed the \"learn your baseline\" threshold and recovery stayed blank forever. NOOP now seeds the baseline from the nights it computes on-device too, so after about four nights of wear recovery lights up on its own. It stays honestly blank until then, and a real WHOOP import still wins per day. The natural payoff of the v1.52 offload work. Thanks to a community contribution (#78). (macOS recovery-seeding parity is a follow-up; version bump only this release.)",
            ]),
        Release(
            version: "1.52",
            title: "WHOOP 5.0/MG history offload (Android)",
            date: "June 2026",
            items: [
                "New (Android, experimental): a WHOOP 5.0/MG can now offload its stored history, not just stream live HR — the same thing the Mac already did. The 5/MG Bluetooth envelope shifts every field by 4 bytes and its end-of-history marker is a different type than the 4.0's, so the app was silently dropping every \"history finished\" frame and the strap never released its records. NOOP now reads those frames at the right place (matching the Mac), so history can download and feed recovery, strain and sleep. If you have a 5.0/MG, please report whether your history populates — it's experimental until confirmed on more straps. Thanks to a community contribution (#78). (macOS: version bump only — it already had this.)",
            ]),
        Release(
            version: "1.51",
            title: "True battery %, a sync indicator, and HR on imported workouts",
            date: "June 2026",
            items: [
                "Fixed: the battery flashing 100% before correcting to the real value (and sometimes reverting to 100%). A WHOOP 4.0's standard Bluetooth battery characteristic is a stub that always says 100 — the real charge comes from the proprietary battery command — and NOOP read both. It now uses only the real source per strap model. Mac and Android (#77).",
                "New: a pulsing \"Syncing strap history…\" indicator on Today, Sleep and Intelligence while the strap's history is offloading — with a live chunk count — so a half-loaded screen (\"No nights here yet\") reads as in-progress, not final. The Live pill shows \"Bonded · syncing\" too. Mac and Android (#77).",
                "Fixed (Android): imported workouts showed no heart rate. Health Connect sessions carry no summary HR, so avg/max were stored empty — the importer now derives them from the heart-rate samples inside each workout's window, and the Workouts/Today lists also fall back to the strap's own recorded HR for any imported session it was worn through (#77).",
            ]),
        Release(
            version: "1.50",
            title: "Steadier Bluetooth on congested Android phones",
            date: "June 2026",
            items: [
                "Fixed (Android): on phones whose Bluetooth stack gets congested (a Pixel 7 on Android 16 logged dozens of \"busy\" command retries and a few dropped commands in 10 minutes), NOOP now retries a busy command more times with an escalating wait so nothing hard-drops, and re-subscribes the live channels at most once per quiet spell instead of every 30 seconds — that repeated re-subscribing was flooding the link with writes that collide with commands on phones that only allow one Bluetooth operation at a time. Steadier live HR and fewer dropped commands as a result. macOS: version bump only (it uses CoreBluetooth's own queue and isn't affected).",
            ]),
        Release(
            version: "1.49",
            title: "Spanish WHOOP exports now import",
            date: "June 2026",
            items: [
                "Fixed: Spanish WHOOP CSV exports now import. A Spanish export translates both the column headers (Puntuación de recuperación, Variabilidad de la frecuencia cardíaca, and so on) and some filenames (sueño.csv, entrenamientos.csv), so it used to match nothing and reported \"Imported 0 items.\" NOOP now maps the Spanish columns to their canonical fields and recognises the Spanish filenames, so recovery, strain, sleep, HRV and the rest come through correctly. Mac and Android. Thanks to a reporter who supplied a real export's headers (#76) — the same way German was added.",
            ]),
        Release(
            version: "1.48",
            title: "More reliable Bluetooth on newer Android phones",
            date: "June 2026",
            items: [
                "Fixed (Android): on some phones — especially newer ones on Android 13+, and worst on Android 16 — NOOP could silently drop a Bluetooth command when the phone's Bluetooth stack was momentarily busy, instead of retrying it. The dropped command was often the one that starts live heart rate, sets the strap clock, or acknowledges a chunk of history — so live HR sometimes never started and overnight data didn't come through, even though the strap and pairing were fine. NOOP now retries a rejected command and paces the writes so the stack keeps up. Thanks to a detailed strap log from a Pixel 7 on Android 16 (#77). (macOS: version bump only — it uses CoreBluetooth's own write queue and was never affected.)",
            ]),
        Release(
            version: "1.47",
            title: "Auto-sync Health Connect (Android)",
            date: "June 2026",
            items: [
                "New (Android): an opt-in auto-sync for Health Connect. Turn it on under Data Sources → Health Connect and NOOP re-pulls new data (e.g. from a Samsung Galaxy Watch via Samsung Health) each time you open it, if it's been longer than your chosen 6 / 12 / 24h interval. Read-only, never overwrites your strap data, default OFF. Thanks to a community contribution. (macOS: version bump only.)",
            ]),
        Release(
            version: "1.46",
            title: "History dates fixed for revived straps, gestures during sync, clearer pairing",
            date: "June 2026",
            items: [
                "Fixed: if your strap sat unused for a while its clock drifts, and your offloaded history was landing months in the past — live HR worked but nothing else showed up as \"today.\" NOOP now corrects the timestamps when the strap's clock is clearly stale, so your history lands on the right days. Mac and Android. Thanks to a detailed bug report (#72).",
                "Fixed: double-tap (and wrist on/off) now keep working during a history sync. They were being swallowed while the strap offloaded its backlog — very noticeable on a WHOOP 5.0/MG, where that sync runs for minutes. Mac and Android (#69).",
                "New: the Live screen now tells you whether you have a real encrypted pairing (\"Bonded\") or just live heart rate over the open profile (\"Live HR — not fully paired\"). The encrypted bond is what unlocks buzz, alarms, double-tap and history sync, so it's now obvious when those are available. Plus a tip on entering 5.0/MG pairing mode (tap the band). Mac and Android (#69).",
            ]),
        Release(
            version: "1.45",
            title: "Clearer pairing guidance for WHOOP 5.0/MG",
            date: "June 2026",
            items: [
                "Improved (Mac): live heart rate on a WHOOP 5.0/MG streams even before the strap is fully paired — but buzz, alarms, double-tap and full history sync all need that real pairing. NOOP now keeps the \"free the strap from the WHOOP app\" guidance visible (in clearer wording) whenever the strap isn't fully paired, so it's obvious what to do to unlock the rest. Thanks to a 5.0/MG report (#69).",
            ]),
        Release(
            version: "1.44",
            title: "Fixes a false \"pairing refused\" warning (Mac)",
            date: "June 2026",
            items: [
                "Fixed (Mac): the \"Pairing refused\" banner could stay up on the Live screen even after your strap had bonded and live heart rate was streaming — a stale warning on a connection that was actually fine. It now clears the moment the link bonds. Thanks to a 5.0/MG report (#69).",
            ]),
        Release(
            version: "1.43",
            title: "Your whole day's heart rate, on the dashboard",
            date: "June 2026",
            items: [
                "New: Control Center now shows a 24-hour heart-rate trend — your continuous heart rate across today, read straight from the strap's own history (so it's there even for the hours the app was closed, not just while it's open). It plots 5-minute averages with the day's low, average and high underneath. Mac and Android. Thanks to the requests on Reddit.",
            ]),
        Release(
            version: "1.42",
            title: "Reconnects automatically after an update (Android)",
            date: "June 2026",
            items: [
                "New (Android): NOOP now reconnects to your strap automatically when the app starts — so after an app update (or any restart) you don't have to tap Connect again. It reconnects straight to the strap you last paired, as soon as it's in range, with no re-scan. Respects \"Keep connected in the background\" (turn that off if you'd rather connect by hand). Thanks to a community report (#67).",
            ]),
        Release(
            version: "1.41",
            title: "Update check shows what's new",
            date: "June 2026",
            items: [
                "Small follow-up: when Check for updates finds a newer version, it now shows what's new in it right there in Settings → About — so you can see what you're getting before you tap Download.",
            ]),
        Release(
            version: "1.40",
            title: "Check for updates",
            date: "June 2026",
            items: [
                "New: a Check for updates button in Settings → About. It asks GitHub for the latest version and, if there's a newer one, links you straight to the download — so you're not stuck on an old build. It runs ONLY when you tap it: no background checks, no auto-updating, and nothing about you is sent — it just reads the latest version number. Manual, and in your control. (On Mac this is the first thing that touches the network; it stays dormant until you tap the button.)",
            ]),
        Release(
            version: "1.39",
            title: "Wrist alerts for incoming calls (Android)",
            date: "June 2026",
            items: [
                "New (Android): buzz your strap when a call comes in — regular phone calls and supported VoIP apps — with its own Calls section in Notifications settings, separate from app alerts. The call buzz repeats a few times then stops, so you won't miss it. Privacy-first as always: NOOP never reads the number, the caller, or any notification content — only that a call is ringing; the Phone-calls permission is requested only when you turn that toggle on. Thanks to a community contributor (#66).",
            ]),
        Release(
            version: "1.38",
            title: "Smoother during long history syncs (Mac)",
            date: "June 2026",
            items: [
                "Improved (Mac): NOOP stays responsive while your strap syncs a long stretch of history and while the dashboard recomputes. Sync data is now handled as bulk traffic — drained in small batches and kept out of the live UI parser — the strap log no longer floods with a line for every sync acknowledgement, and the heavy recovery/strain/sleep analysis runs off the main thread. So the app no longer hitches during a big offload. Thanks to a community contributor (#64, #65).",
            ]),
        Release(
            version: "1.37",
            title: "New first-run onboarding (Mac + Android)",
            date: "June 2026",
            items: [
                "A proper guided setup the first time you open NOOP — the same flow on Mac and Android: what NOOP is and what to expect, then Bluetooth, putting your strap on, connecting, a little celebration when it bonds, your profile, optional history import, and wrist alerts. Permissions are now asked only on the step that explains them (nothing fires at launch), and the background-connection service is only promoted once you finish. Cleaner, calmer, and consistent across platforms. Thanks to a community contributor (#36/#63).",
                "Live heart-rate zones and %-of-max now use the real max heart rate from your profile (your manual override, or the age-based estimate) instead of a fixed default.",
            ]),
        Release(
            version: "1.36",
            title: "Android: reliable reconnect after a dropout",
            date: "June 2026",
            items: [
                "Fixed (Android): if your strap dropped — out of range, or after a while in the background — NOOP could get stuck \"disconnected\" and never reconnect, no matter how many times it rescanned; the only fix was forcing the strap into pairing mode. The cause: a bonded strap that isn't advertising can't be found by a Bluetooth scan, and reconnect was scan-only. It now reconnects DIRECTLY to your known strap (the OS reconnects as soon as it's back in range, no scan needed), so it recovers on its own. (The Mac already reconnected this way.)",
            ]),
        Release(
            version: "1.35",
            title: "WHOOP 5.0/MG buzz — the real command (matched byte-for-byte)",
            date: "June 2026",
            items: [
                "WHOOP 5.0/MG: the buzz now sends the exact haptics command a working 5.0 app uses — the right command number (0x13), the right 12-byte payload (the \"notify\" vibration pattern), and a framing fix (4-byte padding) that the longer payload needs. NOOP's command is now byte-for-byte identical to the working app's, verified by a test. So Test buzz, wrist alerts and the smart-alarm buzz should now actually vibrate a bonded 5.0/MG. (This supersedes the v1.34 attempt, which had the command number but not the payload.) WHOOP 4.0 buzz is unchanged. If you have a 5.0/MG, please confirm on issue #48.",
            ]),
        Release(
            version: "1.34",
            title: "WHOOP 5.0/MG buzz — trying the right command (experimental)",
            date: "June 2026",
            items: [
                "Experimental (WHOOP 5.0/MG only): the buzz now uses the 5/MG-specific haptics command (opcode 0x13) instead of the WHOOP 4.0 one — a capture from a real MG showed the strap rejecting the old command, and a working third-party app uses 0x13. The exact vibration pattern is still being finalised, so if your 5/MG doesn't buzz yet, that's expected — please share a strap log on issue #48 so we can confirm the strap now accepts the command. WHOOP 4.0 buzz is completely unchanged.",
            ]),
        Release(
            version: "1.33",
            title: "Smart alarm: the time you set is the time that fires",
            date: "June 2026",
            items: [
                "Fixed: the Smart alarm wake time didn't always reach the strap. If you changed the time while the strap wasn't actively connected, the new time silently never transmitted — so the strap kept its old time (you set 07:15, but it still buzzed at 07:00). NOOP now re-sends the alarm time every time the strap reconnects, so the time you set is the time that fires. Mac and Android.",
            ]),
        Release(
            version: "1.32",
            title: "Today trends stay within their window (Mac)",
            date: "June 2026",
            items: [
                "Fixed (Mac): the Today screen's metric sparklines are labelled a \"14-day trend\", but if a metric had fewer than two readings in that window it quietly fell back to your entire history — so an old import could draw months-old data as if it were a current trend. The sparklines now stay strictly within their window, and a metric whose latest reading is older than the window shows \"—\" rather than a stale number. Thanks to a community contributor (#49). (Android already windowed these correctly.)",
            ]),
        Release(
            version: "1.31",
            title: "No more HR spike when you reopen the app",
            date: "June 2026",
            items: [
                "Fixed: when you reopened NOOP or returned to the Live screen, your heart rate could briefly show a high stale number (around 100) and then drift back down over several seconds. The strap was fine — the app was re-showing the last smoothed value from before the gap, until fresh readings refilled the averaging window. The hero number now blanks to \"—\" on resume and shows your real heart rate the instant the first fresh reading arrives. Both Mac and Android.",
            ]),
        Release(
            version: "1.30",
            title: "Workouts: correct source pill for Health Connect (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): on the Workouts page, sessions imported from Health Connect showed an \"Apple\" pill in the Src column. The badge only knew \"Whoop or Apple\", so anything that wasn't a WHOOP workout was labelled Apple. It now shows a distinct \"HC\" (Health Connect) pill in its own colour, alongside \"Whoop\" and \"Apple\". Follow-up to #53 — the Today page was fixed in 1.28; this is the Workouts list.",
            ]),
        Release(
            version: "1.29",
            title: "Re-scan actually scans on Android",
            date: "June 2026",
            items: [
                "Fixed (Android): tapping Re-scan in Settings — or Connect on the Live screen — could do nothing at all. On Android 12 and newer a Bluetooth scan needs the Nearby devices permission, and if you'd dismissed or revoked it the button failed silently with no prompt (the Pixel 9 report in #1). Both buttons now ask for the permission first, so the scan actually starts, and they show a clear \"Searching…\" state while looking for your strap (and can't be re-tapped mid-scan). The Live control buttons also stay on one line on narrow phones. Thanks to the reporter (#1) and to a community contributor (#54/#55).",
            ]),
        Release(
            version: "1.28",
            title: "Health Connect: correct labels + workout types (Android)",
            date: "June 2026",
            items: [
                "Fixed (Android): two Health Connect issues. On the Today page, Health Connect data was shown under an \"Apple Health\" pill — it now has its own \"Health Connect\" row in the Data Sources footer, matching the Data Sources screen. And workout types were mislabelled (a walking workout could show as swimming) because the exercise-type code map had the wrong numbers; it now uses Health Connect's own constants, so walking is walking, swimming is swimming, and so on. New imports are right immediately; re-import your Health Connect data to relabel any that came in before.",
            ]),
        Release(
            version: "1.27",
            title: "Wrist alerts work on Android",
            date: "June 2026",
            items: [
                "Fixed (Android): you couldn't turn wrist alerts on — NOOP didn't show up in your phone's Notification Access list, so there was nothing to grant. NOOP now registers a notification listener (so it appears there); grant access and enable wrist alerts, and your strap buzzes when your chosen apps notify you — respecting your per-app patterns, quiet hours, and only-when-worn. Privacy: it reads only WHICH app notified, never the message content, and nothing leaves your phone. (The buzz works on WHOOP 4.0; 5.0/MG haptics are still being decoded.)",
            ]),
        Release(
            version: "1.26",
            title: "Smart alarm actually works on Android",
            date: "June 2026",
            items: [
                "Fixed (Android): the Smart alarm in Automations didn't work — the toggle reset the moment you left the screen, and the wake time was stuck at 07:00 with no way to change it. It's now a real, saved setting with a proper time picker, and on WHOOP 4.0 it arms the strap's own firmware alarm, so your wrist buzzes at your wake time even if your phone is asleep or NOOP is closed (matching the Mac). Connect the strap to arm it. (On 5.0/MG the alarm command isn't verified yet — same situation as the buzz.)",
            ]),
        Release(
            version: "1.25",
            title: "WHOOP 5.0/MG history download (experimental) + pairing help (Mac)",
            date: "June 2026",
            items: [
                "Experimental (Mac): once your WHOOP 5.0/MG is properly paired (see below), NOOP now attempts to download the strap's stored history — the missing piece for on-device 5.0 recovery, strain and sleep. It's brand-new and needs real-hardware testing; if it works you'll see the offload run in the strap log. WHOOP 4.0 is completely unaffected.",
                "Clearer 5.0/MG pairing: you can't just scan for a 5.0/MG — it has to be in pairing mode and freed from the official WHOOP app first (otherwise pairing is refused with \"Encryption is insufficient\"). The \"free your strap\" tip now shows right on the Live screen (it was hidden in Settings), and the README has a step-by-step pairing guide.",
            ]),
        Release(
            version: "1.24",
            title: "Switch between your WHOOP 4 and 5.0 (Mac + Android)",
            date: "June 2026",
            items: [
                "Fixed: if you own both a WHOOP 4 and a 5.0/MG, you couldn't switch between them — the strap picker on the Live screen disappeared after your first pairing and never came back. It now stays available whenever you're not actively streaming, and choosing the other model cleanly drops the old strap so the new one connects fresh. Pick your strap, hit Scan & Connect, done.",
            ]),
        Release(
            version: "1.23",
            title: "WHOOP 5.0 history decoding comes to Android",
            date: "June 2026",
            items: [
                "Decoding progress (WHOOP 5.0, Android): Android now decodes the same WHOOP 5.0/MG history the Mac learned to read in 1.21 — heart rate, R-R, motion, wrist-contact and skin temperature — each verified against real captured data and only kept when it's physically sensible. This brings Android to parity with the Mac on 5.0 history decoding; it's the groundwork that lights up when the strap's history download lands for 5.0.",
            ]),
        Release(
            version: "1.22",
            title: "Battery refresh on WHOOP 5.0/MG (Mac + Android)",
            date: "June 2026",
            items: [
                "Fixed: the \"Refresh battery\" button did nothing on WHOOP 5.0/MG. It was sending a WHOOP 4-only command the 5.0 ignores, so the battery only updated on its own schedule. Both apps now read the strap's standard battery level directly the moment you tap refresh — and once more as soon as you connect, so a fresh reading shows up right away. WHOOP 4 is unchanged.",
            ]),
        Release(
            version: "1.21",
            title: "Reading more from your WHOOP 5.0 (Mac)",
            date: "June 2026",
            items: [
                "Decoding progress (WHOOP 5.0): NOOP now reads skin temperature, motion/activity and wrist-contact from your 5.0's stored history — each verified against real data (e.g. ~30.6 °C on the wrist, dropping to room temperature off it) and only stored when it's physically sensible. These are building blocks toward on-device 5.0 sleep and recovery; nothing changes on screen yet.",
                "Fixed (Mac): corrected which byte NOOP reads the 5.0's optical-pulse channel from — a community reverse-engineering report, cross-checked against our own captured frames, showed it was a counter byte, not the channel. The pulse waveform itself was always decoded correctly; this only affects the channel label.",
            ]),
        Release(
            version: "1.20",
            title: "Strap log stays off the system log (Android)",
            date: "June 2026",
            items: [
                "Changed (Android): the strap connection log is no longer copied to the phone's system log (logcat) by default. A normal user has no reason to write the Bluetooth connection log to the device-wide log, so it's now off unless you turn on Settings → Strap → \"Debug logging\" (there for developers watching a session over adb). The in-app log and \"Share strap log\" export work exactly as before, so bug reports are unaffected.",
            ]),
        Release(
            version: "1.19",
            title: "Import polish (Mac) + WHOOP 5 optical decode",
            date: "June 2026",
            items: [
                "Changed (Mac): while an import is running, both Data Sources buttons now lock and only the source that's actually importing shows a spinner — so you can't start a WHOOP and an Apple Health import at the same time, and the loading state always points at the right card. Follow-up to the 1.18 status-message fix.",
                "Decoding progress (WHOOP 5.0): NOOP now reads the strap's raw optical pulse (PPG) waveform from its stored history — a 24 Hz trace verified against your own heart rate, with no external reference. Nothing changes on screen yet; it's a building block toward 5.0 recovery and strain.",
            ]),
        Release(
            version: "1.18",
            title: "Import fixes — both sources, all data types",
            date: "June 2026",
            items: [
                "Fixed (Mac): importing an Apple Health export overwrote your WHOOP import's status message in Data Sources — the two shared one status line, so it looked like Apple Health replaced your WHOOP data. Each source now keeps its own status and result (and the Apple Health card shows its own). Your data was always stored separately; only the on-screen message was wrong.",
                "Fixed (Android): a single Health Connect data type failing (e.g. \"count must not be less than 1\" on some devices) aborted the entire import. Each data type is now read independently, so one quirky type is skipped and everything else still imports.",
            ]),
        Release(
            version: "1.17",
            title: "Sleep from WHOOP 4 on more firmware (Mac)",
            date: "June 2026",
            items: [
                "Fixed (Mac): no sleep recorded from a WHOOP 4 on certain firmware. NOOP stages your sleep from the strap's overnight motion data — but historical records from firmware versions it hadn't mapped were being silently dropped, so the offload finished yet produced no motion → no sleep. NOOP now falls back to the standard record layout for unmapped firmware, accepting it only when it decodes to physically-real data (so it can never store garbage), and surfaces a genuinely-unknown firmware version in the strap log. If your WHOOP 4 wasn't recording sleep, update and wear it overnight while connected.",
            ]),
        Release(
            version: "1.16",
            title: "Health Connect shows as Health Connect",
            date: "June 2026",
            items: [
                "Fixed (Android): data imported from Health Connect was being shown as \"Apple Health.\" It's now filed under its own Health Connect source and counted on the Health Connect card. Nothing was ever lost — it was a labelling bug — and your already-imported data refiles itself automatically the next time you import from Health Connect.",
            ]),
        Release(
            version: "1.15",
            title: "WHOOP 5/MG: the buzz works",
            date: "June 2026",
            items: [
                "The wrist buzz now works on WHOOP 5.0/MG (experimental). Now that live heart rate confirmed a 5/MG strap acts on NOOP's commands, the haptic buzz — Test buzz, the smart alarm — is wired through the same path. Try Test buzz in Notifications; if it doesn't fire on your 5/MG strap, let us know. (Battery already worked on 5/MG via the standard profile.) WHOOP 4.0 is unchanged.",
            ]),
        Release(
            version: "1.14",
            title: "Android Today: clearer empty states",
            date: "June 2026",
            items: [
                "Android Today now reads honestly when you don't have data for the actual day yet: missing metrics show a clear \"No Data\" instead of blank dashes, and the recovery ring no longer shows a depleted 0% when there's simply no score for today. Added a Today footer with your recent workouts and Data Sources counts, so imported history is clearly labelled as history — matching the Mac. Completes the stale-import cleanup from the last few releases.",
            ]),
        Release(
            version: "1.13",
            title: "WHOOP 5/MG heart rate on Android",
            date: "June 2026",
            items: [
                "WHOOP 5.0/MG live heart rate now works on Android. Once the strap bonds, NOOP subscribes to its realtime data channels and decodes the heart-rate stream the same way the Mac does — before, Android only listened on the standard profile, which a 5/MG strap doesn't stream, so it bonded but showed no HR. Still experimental: 5/MG owners, update and share a strap log if it doesn't come through. WHOOP 4.0 is unaffected.",
            ]),
        Release(
            version: "1.12",
            title: "WHOOP 5/MG heart rate on Mac + a Readiness fix",
            date: "June 2026",
            items: [
                "WHOOP 5.0/MG on Mac: the secure pairing now completes and live heart rate comes through. NOOP waits for the strap to bond before subscribing to its data channels — subscribing too early was the silent failure — then asks it to start streaming with the right framing. If the strap won't bond on first connect, NOOP now tells you to close the official WHOOP app and put the strap in pairing mode (blue LEDs flashing), which is what lets it pair. Still experimental on 5/MG; built from a 5/MG owner's verified flow. (Android 5/MG bonding landed in v1.10; WHOOP 4.0 is untouched.)",
                "Readiness now reflects today, not a stale import. After importing months-old WHOOP history, the \"Should you push today?\" card was still reading off the newest imported day. It now anchors to your real calendar day on both Mac and Android — completing the v1.11 dashboard fix — so an old import no longer drives today's readiness.",
            ]),
        Release(
            version: "1.11",
            title: "Today reflects today (not stale imports)",
            date: "June 2026",
            items: [
                "Fixed the dashboard treating the newest imported day as \"today\" after a historical import — so months-old data showed as today's recovery/readiness. Today now shows only a row for your actual calendar date, and the 14-day sparklines and Trends W/M/3M windows are anchored to today. Older imports stay visible under the wider ranges / All history. Fixed on both Mac and Android.",
            ]),
        Release(
            version: "1.10",
            title: "5/MG bonding on Android + Health Monitor fix",
            date: "June 2026",
            items: [
                "WHOOP 5.0/MG on Android: fixed the strap connecting but never bonding (it wrote the opening message unacknowledged, which didn't trigger the encrypted pairing the strap needs before it will stream). It's now a confirmed write that triggers bonding, so live heart rate can come through. Still experimental — 5/MG owners, please update and share a strap log.",
                "Fixed the Health Monitor heart-rate freezing when you opened it from the Live page. Leaving Live was switching the live HR stream off entirely; the stream now stays on while any live-HR screen is open.",
            ]),
        Release(
            version: "1.9",
            title: "Fix: bonded but no live data (Android)",
            date: "June 2026",
            items: [
                "Fixed an Android bug where the strap would connect and bond but show no live data at all — heart rate, battery, worn and events all blank — on some phones (it shows up reliably on newer Android). A Bluetooth callback-threading race let the pairing write starve the data-stream subscriptions; NOOP now pins all Bluetooth callbacks to one thread and retries a momentarily-busy subscription, so the stream comes up reliably. Reported, diagnosed and hardware-verified by a community contributor.",
            ]),
        Release(
            version: "1.8",
            title: "Strap-log export on Mac + a Health Monitor fix",
            date: "June 2026",
            items: [
                "Mac: you can now export the strap log — Copy / Save… on the Live screen's strap log — so Mac users can attach it to a bug report too (Android has had this since 1.6).",
                "Fixed the Health Monitor heart-rate chart sitting on a flat line: it now plots your live heart rate over time instead of deriving from sparse R-R data.",
            ]),
        Release(
            version: "1.7",
            title: "WHOOP 5/MG frame capture",
            date: "June 2026",
            items: [
                "New opt-in “Record puffin frames” under Settings → Experimental. While connected to a WHOOP 5/MG strap it logs the raw frames — each stamped with your live heart rate as a cross-check — to a file you can export, so 5/MG owners can contribute the data we need to decode recovery, strain and sleep. Read-only, off by default; WHOOP 4.0 is unaffected. Built on community contributions toward the 5/MG protocol.",
            ]),
        Release(
            version: "1.6",
            title: "Share strap logs, and a worn-status fix",
            date: "June 2026",
            items: [
                "New on Android: Settings → Strap → “Share strap log” exports the connection log to a file you can attach to a bug report. If your strap won't connect or behaves oddly, this is the single most helpful thing you can send.",
                "Fixed on Android: the “Worn” status always reading Off. It now assumes you're wearing the strap until the strap says otherwise, matching the Mac app.",
            ]),
        Release(
            version: "1.5",
            title: "WHOOP 5/MG: secure-pairing fix",
            date: "June 2026",
            items: [
                "WHOOP 5.0/MG: fixed connecting getting stuck at “Finishing the secure pairing handshake.” NOOP now establishes the encrypted pairing first, then subscribes — so live heart rate can come through instead of hanging. Still experimental on 5/MG: if you have one, please try it and share your strap log on GitHub so we can keep improving it.",
            ]),
        Release(
            version: "1.4",
            title: "Live heart rate that doesn't freeze",
            date: "June 2026",
            items: [
                "Fixed live heart rate freezing on a stale number mid-session. NOOP now keeps the strap's realtime stream re-armed and, if the link goes quiet, quietly reconnects on its own — no more disconnect-and-reconnect by hand to un-stick it. (Android now matches how the Mac app already behaved.)",
                "Hardened the Bluetooth frame reader so a single corrupt packet can't wedge the live stream until you reconnect.",
            ]),
        Release(
            version: "1.3",
            title: "Stays connected in the background",
            date: "June 2026",
            items: [
                "NOOP now keeps your strap connected when the app is closed. On Android it shows a quiet ongoing notification and keeps streaming your heart rate; on Mac, just close the window and NOOP keeps running from the menu bar.",
                "New “Keep connected in the background” toggle in Settings → Strap (on by default). Turn it off and NOOP disconnects whenever you close the app.",
                "Fixed the strap dropping the moment you closed the app, and made sure the notification permission is actually requested.",
            ]),
        Release(
            version: "1.2",
            title: "Readiness, and the start of WHOOP 5/MG",
            date: "June 2026",
            items: [
                "New Readiness card on Today — a “should you push today?” read from your own history: HRV vs your baseline, resting-heart-rate drift, sleeping respiratory rate, training-load balance and training variety, rolled into one headline.",
                "WHOOP 5/MG: live heart rate now works. Deeper 5/MG metrics (recovery, strain, sleep) are still experimental and being worked on.",
                "Opt-in WHOOP 5/MG protocol probes under Settings → Experimental, for 5/MG owners who want to help map the protocol.",
                "German and other localized WHOOP exports now import with real values, not blanks.",
                "Fixed the WHOOP 5/MG “stuck connecting” state and the macOS “Choose export” button.",
            ]),
        Release(
            version: "1.1",
            title: "Scores live from the strap",
            date: "June 2026",
            items: [
                "Recovery, strain and sleep now compute live on-device from the strap, not only from an import. They calibrate over your first few nights, like any recovery wearable.",
                "Pick your strap (WHOOP 4.0 or 5.0/MG) before connecting, so it looks for the right one.",
                "macOS is now a universal build that runs on both Intel and Apple Silicon.",
            ]),
        Release(
            version: "1.0",
            title: "First release",
            date: "June 2026",
            items: [
                "Pair directly with a WHOOP strap over Bluetooth — no WHOOP account, no cloud.",
                "Compute recovery, strain, HRV and sleep locally on your own device.",
                "Bring your history: import a WHOOP export, an Apple Health export, or Android Health Connect.",
            ]),
    ]

    /// Expectation-setting points shown during onboarding and at the top of "What's New". This is the
    /// “what is this and what should I expect” story, so people don't have to go read GitHub.
    struct Expectation: Identifiable {
        let icon: String      // SF Symbol
        let title: String
        let body: String
        var id: String { title }
    }

    static let expectations: [Expectation] = [
        Expectation(
            icon: "flask",
            title: "Independent, and experimental",
            body: "NOOP is a personal, open project — not the WHOOP app, and not affiliated with WHOOP. It reads a strap you own, on your own device. Treat it as a capable work-in-progress rather than a finished product."),
        Expectation(
            icon: "checkmark.seal",
            title: "WHOOP 4.0 is the supported path",
            body: "WHOOP 4.0 is tested and works end to end. WHOOP 5.0/MG is newer: live heart rate works today, but deeper metrics (recovery, strain, sleep) for 5/MG are still being figured out. NOOP always tells you what's live versus still building."),
        Expectation(
            icon: "hourglass",
            title: "Your scores build over a few nights",
            body: "Live heart rate is instant. Recovery, strain and sleep sharpen as NOOP learns your baseline over your first nights of wear. Want your history now? Import your WHOOP export in Data Sources and it backfills in about a minute."),
        Expectation(
            icon: "lock.shield",
            title: "Everything stays on your device",
            body: "No account, no cloud, no sync. NOOP talks only to your strap and keeps everything local. Your data is yours alone."),
    ]
}
