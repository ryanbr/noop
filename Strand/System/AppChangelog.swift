import Foundation

/// Single source of truth for the in-app "What's New" screen and the expectation-setting copy used
/// in onboarding. Mirrored byte-for-byte by the Android `AppChangelog.kt` and the repo CHANGELOG.md
/// so every surface tells the same story.
enum AppChangelog {

    /// Bump this when you add a release below. The "What's New" sheet shows automatically when the
    /// stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
    static let currentVersion = "1.45"

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
