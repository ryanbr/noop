import Foundation

/// Single source of truth for the in-app "What's New" screen and the expectation-setting copy used
/// in onboarding. Mirrored byte-for-byte by the Android `AppChangelog.kt` and the repo CHANGELOG.md
/// so every surface tells the same story.
enum AppChangelog {

    /// Bump this when you add a release below. The "What's New" sheet shows automatically when the
    /// stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
    static let currentVersion = "1.27"

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
