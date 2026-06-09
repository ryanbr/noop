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
