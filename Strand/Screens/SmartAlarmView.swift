import SwiftUI
import StrandDesign
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this
/// platform deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android,
/// which has the exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle
/// evening reminder — and we say plainly why there's no wake alarm, rather than promising one we
/// can't keep.
struct SmartAlarmView: View {
    // #766: this is now the ONE alarm surface. The strap's silent firmware wake-alarm used to live in a
    // separate card over in Automations, which let users conflate it with the wind-down reminder; it's
    // moved here so every wake/wind-down control sits together. Needs the model (to arm/disarm the strap
    // alarm over BLE) and the behavior store (the alarm's persisted on/time/weekdays).
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore

    @State private var windDownOn = WindDownNudge.isEnabled
    /// Shown when the user flips the nudge on but notifications are denied at the OS level — the reminder
    /// can never fire, so we revert the switch and point them to Settings instead of failing silently.
    @State private var showNotifDeniedAlert = false
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides

    // #34: consecutive times the strap reported back a DIFFERENT alarm time than we sent (set in
    // FrameRouter). ≥2 = the strap is persistently refusing the alarm (a corrupted clock/alarm register),
    // which the strapRejectedCard surfaces with reset guidance. @AppStorage so it updates live.
    @AppStorage("alarm.rejectStreak") private var alarmRejectStreak = 0
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        // #766: retitled to "Alarms" because it now holds BOTH the strap's silent wake-alarm and the
        // evening wind-down reminder, so naming it "Wind-Down" undersold it. One surface, clearly labelled.
        ScreenScaffold(title: "Alarms",
                       subtitle: "Your strap wake-alarm and the evening wind-down reminder, in one place.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                windowHero
                strapAlarmCard
                strapRejectedCard   // #34: only shows when the strap keeps refusing the alarm
                honestyCard
                windDownCard
            }
        }
        .alert(String(localized: "Notifications are off"), isPresented: $showNotifDeniedAlert) {
            Button(String(localized: "Open Settings")) { Self.openNotificationSettings() }
            Button(String(localized: "Not now"), role: .cancel) {}
        } message: {
            Text("Turn on notifications for NOOP in Settings to get your wind-down reminder.")
        }
    }

    /// Deep-link to the OS notification settings so a user who denied can flip it back on — the system
    /// permission dialog only appears once, so Settings is the only recovery path.
    private static func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // A small Rest-tinted hero — the wind-down readout as a clean time pairing (wind-down → wake)
    // over a scenic Rest backdrop, so a glance gives the night's shape. It's about winding down to
    // sleep, so it reads in the Rest world (indigo) rather than the brand-green chrome below.
    private var windowHero: some View {
        ZStack {
            ScenicHeroBackground(domain: .rest)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                Text("Tonight").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    heroTime(label: "Wind down",
                             time: windDownOn ? timeLabel(WindDownNudge.nudgeMinuteOfDay()) : "—",
                             tint: StrandPalette.restColor)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    // "Wake" was the wind-down INPUT wearing the name of the thing that wakes you, in the
                    // largest type on the screen, above both cards. It is the first figure a reader sees
                    // and it is not their alarm. Named for what it is instead.
                    heroTime(label: "Usual wake",
                             time: timeLabel(wakeMinutes),
                             tint: StrandPalette.restBright)
                    // The alarm is deliberately NOT a third figure on this arrow. The arrow is an
                    // arithmetic pair (the nudge is derived from the usual wake time) and the alarm is
                    // not part of that derivation, so chaining it would claim the nudge is timed for the
                    // alarm. It gets the countdown block below instead, which also keeps the alarm time
                    // from appearing twice in one hero.
                    Spacer(minLength: 0)
                }
                // How long until it actually goes off. "10:00" does not say whether that is nine hours
                // away or thirty-three, which is the thing you want at a glance. It lives HERE rather
                // than beside the picker in the card below: that spot is six rows into the second card,
                // under a four-line paragraph, so you only meet it once you are already editing the
                // alarm. The hero is where the eye lands. Exactly one countdown on the screen, because
                // two live ones start the next "which of these is the real one" question, which is the
                // question this whole screen exists to stop.
                //
                // Re-rendered once a minute rather than computed at view build, since a countdown frozen
                // at whatever it read when the screen opened is worse than none. The TimelineView wraps
                // ONLY this line, so the 60s tick cannot re-render the rest of the screen.
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    if let countdown = strapAlarmCountdown(from: tick.date) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(countdown)
                                .font(StrandFont.number(22))
                                .foregroundStyle(StrandPalette.accent)
                                .fixedSize(horizontal: false, vertical: true)
                            // The absolute companion, the way a phone's clock app pairs them: the
                            // countdown is the glance, the stamp is what you check when it matters. It
                            // carries the DATE, which is the half that actually settles "tonight or
                            // tomorrow" and which a bare time never can.
                            if let stamp = nextStrapAlarmStamp(from: tick.date) {
                                Text(stamp)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(windDownOn
                     ? "A calm nudge \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before your usual wake time."
                     : "Turn on the wind-down reminder below to land at your usual wake time rested.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroTime(label: LocalizedStringKey, time: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(time)
                .font(StrandFont.number(28))
                .foregroundStyle(tint)
        }
    }

    // #34: shown ONLY when the strap has repeatedly reported back a different alarm time than we sent —
    // i.e. its firmware is refusing the write (a reset/corrupted clock/alarm register). Gated on the alarm
    // being on and a rejection STREAK (≥2) so a one-off readback quirk never nags. Actionable: a strap
    // reset via the official app clears it; the phone Clock alarm covers the gap meanwhile.
    @ViewBuilder private var strapRejectedCard: some View {
        if behavior.smartAlarmEnabled && alarmRejectStreak >= 2 {
            StrandCard(padding: 20) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your strap isn't accepting the alarm")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("The strap keeps reporting a different time than NOOP sends, so its firmware alarm won't fire at your wake time — usually a strap whose clock or alarm has reset. Reset the strap in the official WHOOP app (or fully charge it and reconnect), and keep your phone's Clock alarm as your wake until it takes.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // The up-front, honest note about the difference between the strap's silent buzz (above) and a loud
    // phone wake. The strap alarm is real, but it's a gentle wrist buzz, not a sound, so we say plainly
    // to keep a backup, and that the louder smart wake lives on Android.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The strap alarm is a silent buzz, not a sound")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("The wake-alarm above buzzes your wrist from the strap's own firmware. It can't sound a loud alarm. We also schedule a backup notification at your wake time, but a sideloaded app can't sound a guaranteed wake on this device (that needs a critical-alert permission this build doesn't have), so Focus or silent mode can still mute it. Keep your phone's built-in Clock alarm as your real backup. NOOP's phone-based smart wake (light-sleep detection) is available on the Android app.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Strap silent wake-alarm (#766, moved here from Automations)

    // The strap's own firmware alarm: a silent wrist buzz at the chosen time, armed over BLE so it fires
    // even if the phone is asleep or NOOP is closed. Lifted verbatim (behaviour intact) out of
    // AutomationsView.alarmCard so users stop conflating it with the wind-down reminder below.
    private var strapAlarmCard: some View {
        StrandCard(padding: 20, tint: behavior.smartAlarmEnabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "alarm.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Strap wake-alarm")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake me with a strap buzz")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Arms the strap to buzz at your wake time, even if NOOP is closed. Sends the exact alarm command the official app sends, confirmed buzzing on a real WHOOP 4.0 (community wire capture + on-device test, #535). Keep a backup alarm for anything you truly can't miss.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $behavior.smartAlarmEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Wake me with a strap buzz")
                }
                .frame(minHeight: 42)

                if behavior.smartAlarmEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Wake at").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.compact)
                            // Distinct from the wind-down picker's label below. Both were "Wake time",
                            // so VoiceOver announced the alarm and the reminder's timing input by the
                            // same name, on the same screen, with different values.
                            .accessibilityLabel("Strap alarm wake time")
                    }
                    .frame(minHeight: 42)
                    // The per-day overrides that re-time THIS alarm (#1864) are edited under the
                    // wind-down card, so read on its own this card can say "10:00" during a week whose
                    // Saturday fires at 20:30. Checking your alarm is exactly what someone opens this
                    // card to do, so the qualifier belongs against the number it qualifies. Shown only
                    // when an override actually exists, because otherwise the picker IS the whole truth.
                    if !overrides.isEmpty, let next = nextStrapAlarmLabel {
                        Text("Some days have a time of their own, set under the evening reminder below. Next buzz \(next).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    alarmWeekdayPicker
                    // #864: a WHOOP 5/MG only arms its firmware alarm when Protocol probes is on (see
                    // BLEManager.armStrapAlarm, which logs "not armed" and returns otherwise). Without this
                    // branch the card claimed "Armed on the strap itself" to a 5/MG owner whose strap was
                    // NOT armed, an honest-data violation (reporter: 5/MG, Experimental off, never buzzed).
                    // Mirrors the Android SmartAlarmScreen StrapAlarmCard wording exactly. The else copy
                    // was truth-synced once a real 4.0 wake was confirmed (PR #535: official-app wire
                    // capture + on-device buzz by the capture author); 5/MG remains experimental, so this
                    // gated branch keeps its backup-alarm wording.
                    if model.whoop5Detected && !PuffinExperiment.isEnabled {
                        Text("WHOOP 5/MG strap alarms require Protocol probes (Test Centre → 5/MG protocol diagnostics). Your wake time is saved, but the strap is not armed yet. Keep a backup alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.whoop5Detected {
                        // 5/MG with Protocol probes ON: the rev-4 command arms the strap. One wake was
                        // captured on an MG (#864) and one reported on a 5.0 without a log (#2464);
                        // neither repeated, so the copy simplifies both to "reported" and promises none.
                        Text("Armed on the strap with an experimental 5/MG command. Strap-driven wakes have been reported on 5.0 and MG, but are not guaranteed. Keep a backup alarm for anything you cannot miss.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Sends the exact alarm command the official app sends, confirmed buzzing on a real WHOOP 4.0 (community wire capture + on-device test, #535). Keep a backup alarm for anything you truly can't miss.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // #1706: ask the strap what it actually has stored. The readback was otherwise
                        // only reachable by ARMING, so anyone whose alarm is off could not produce the
                        // frame that explains a wrong reported time.
                        //
                        // Shown unconditionally, where the Android twin hides it until bonded. That is a
                        // deliberate platform difference, not drift: the Android card already observes
                        // LiveState, so gating there is free, while this view does not — and pulling
                        // `live` in would re-render the whole alarm screen on every 1 Hz HR tick, which
                        // this codebase keeps parent views clear of on purpose. `getStrapAlarm` no-ops
                        // and logs when nothing is connected, so the worst case is one ignored write.
                        Divider().overlay(StrandPalette.hairline)
                        Button {
                            model.ble.getStrapAlarm()
                        } label: {
                            Text("Check what the strap has stored")
                        }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        Text("The answer from the strap appears in your strap log and debug export, with the raw bytes it replied with.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmWeekdays) { _ in model.applySmartAlarm() }
        }
    }

    private var windDownCard: some View {
        // Rest-tinted when armed so the active state reads in the sleep world; neutral when off.
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evening").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(StrandPalette.restColor)
                            .accessibilityHidden(true)
                        Text("Wind-down nudge")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to wind down")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A calm evening reminder, timed from your wake time and usual sleep need. It's a suggestion, not an alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $windDownOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Remind me to wind down")
                        .onChangeCompat(of: windDownOn) { on in
                            WindDownNudge.setEnabled(on) { outcome in
                                // Denied at the OS level: the reminder can never fire, so reflect reality
                                // (revert the switch) and surface the path to Settings.
                                if outcome == .denied {
                                    windDownOn = false
                                    showNotifDeniedAlert = true
                                }
                            }
                        }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // Was "Wake time", the same words the strap alarm's own picker uses one card
                            // up. Two pickers called the same thing, holding different times, and only
                            // one of them wakes anybody: a reporter asked outright which time would wake
                            // them. This field is an INPUT to the reminder's arithmetic, so it is named
                            // for what it is rather than for what it sounds like.
                            Text("Your usual wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text("This time does not wake you. It only decides when the evening reminder fires.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Your usual wake time")
                    }
                    Text("You'll be reminded around \(timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    // Answers "so what actually wakes me?" in the one place the question gets asked,
                    // beside the time that does not. Only shown when there IS a strap alarm to name.
                    if let next = nextStrapAlarmLabel {
                        Text("Your strap alarm is what wakes you, next on \(next).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(StrandPalette.hairline)
                    perDaySection
                }
            }
        }
    }

    // PR#554 — per-day wake overrides. A toggle reveals a per-weekday wake-time editor; with it off (or no
    // override set) every evening uses the single wake time above. Each weekday row shows the effective wake
    // (override or the default) and lets the user set or clear that day's time.
    @ViewBuilder private var perDaySection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Different wake time per day")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                // #1864 made these overrides drive the STRAP ALARM as well as the reminder, but the
                // copy stayed written as though they only moved the nudge, and the section still sits
                // under the wind-down card. A day set here re-times the buzz on your wrist. Saying so
                // is the difference between a lie-in and an alarm that goes off on Saturday evening.
                Text("Set a wake time for specific days (a lie-in at the weekend, say). These times move your strap alarm AND the evening reminder on those days.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $perDayOn)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel("Different wake time per day")
                .onChangeCompat(of: perDayOn) { on in
                    // Turning the section OFF clears every override (so the nudge reverts to the single time);
                    // turning it ON just reveals the editor — no override is created until the user sets one.
                    if !on {
                        for weekday in 1...7 { WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil) }
                        overrides = [:]
                        // #1864: re-arm the strap alarm + backup notification so they drop the per-day
                        // times and revert to the single default, matching the wind-down nudge's revert.
                        model.applySmartAlarm()
                    }
                }
        }
        .frame(minHeight: 42)

        if perDayOn {
            VStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    weekdayOverrideRow(weekday)
                }
            }
            .padding(.top, 4)
            Text(untouchedDayExplainer)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// When the strap alarm will next actually buzz, as a localised weekday and time, or nil when there
    /// is no alarm to name.
    ///
    /// Deliberately the NEXT FIRE rather than `smartAlarmMinutes`. With a per-day override set there is no
    /// single alarm time to state, and naming the base one would be wrong on exactly the days the reporter
    /// had changed: their Saturday override reads 20:30 while the base reads 10:00. A line that answers
    /// "what wakes me" has to be right on every day, or it is one more thing on this screen to misread.
    /// `nextSmartAlarmDate` is the same pure resolver `applySmartAlarm` arms the strap from, so this cannot
    /// drift from what the strap is actually told.
    ///
    /// The template formatter also follows the reader's 12/24-hour setting, unlike `timeLabel`.
    private var nextStrapAlarmLabel: String? {
        guard let next = nextStrapAlarm() else { return nil }
        let formatter = DateFormatter()
        // `AppLanguage.activeLocale`, not `.current`: the app language is an in-app setting, so a reader
        // running NOOP in German on an English device must get German weekday words here, while keeping
        // their device's 24-hour convention. The same reason every other formatter in the app uses it.
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEE jj:mm")
        return formatter.string(from: next)
    }

    /// Whether switching the alarm on actually arms anything that will go off.
    ///
    /// A WHOOP 5/MG arms its firmware alarm only with Experimental on: `BLEManager.armStrapAlarm` logs
    /// "not armed" and returns otherwise. That is the #864 case, reported by a 5/MG owner whose strap
    /// never buzzed while this card told them it was armed, and the card carries a warning for it.
    ///
    /// A countdown is a promise, so it must not be made for an alarm that will not exist. On macOS there
    /// is not even a fallback to fall back to: `scheduleSmartAlarmBackupNotification` is `#if os(iOS)`
    /// with no `#else`, so in that state nothing whatsoever happens at the chosen time. Saying "Alarm in
    /// 18 hours" directly above the line admitting the strap is NOT armed would reintroduce the exact
    /// honesty bug one row up from its own fix.
    ///
    /// A strap that is merely disconnected is NOT excluded here: `armStrapAlarm` queues and arms on
    /// reconnect, so the alarm is real and the countdown to it is true.
    private var strapAlarmWillArm: Bool {
        !(model.whoop5Detected && !PuffinExperiment.isEnabled)
    }

    /// The one moment every alarm readout on this screen is derived from, or nil when nothing will fire.
    ///
    /// Single funnel on purpose. This resolver was called from three places, each repeating the gate and
    /// the argument list, which is three chances for one of them to drift from what the strap is actually
    /// armed with. `nextSmartAlarmDate` is the same pure function `applySmartAlarm` arms from, and the
    /// overrides go in so a day with its own time resolves to THAT time.
    ///
    /// `from` is a parameter so the ticking countdown re-resolves against the clock it is given rather
    /// than a `Date()` captured somewhere else.
    private func nextStrapAlarm(from now: Date = Date()) -> Date? {
        guard behavior.smartAlarmEnabled, strapAlarmWillArm else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                           weekdays: behavior.smartAlarmWeekdays,
                                           overrides: overrides,
                                           from: now)
    }

    /// The next alarm as a weekday, date and time: "Mon 21 Sep 10:28".
    ///
    /// The absolute companion to the countdown, the way a phone's clock app pairs them. "In 17 hours" is
    /// what you want at a glance; the stamp underneath is what you check when the answer matters, and it
    /// carries the DATE, which is what actually settles "tonight or tomorrow".
    ///
    /// Takes the SAME clock the countdown was resolved from. Reading `Date()` here instead would give the
    /// two lines two clocks up to a tick apart, and `nextSmartAlarmDate` returns the next strictly-future
    /// fire: straddle that moment and the countdown says "less than a minute" while the stamp names
    /// tomorrow. Two lines disagreeing about one fact is the exact defect this screen exists to remove.
    private func nextStrapAlarmStamp(from now: Date = Date()) -> String? {
        nextStrapAlarm(from: now).map { date in
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.activeLocale
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jj:mm")
            return formatter.string(from: date)
        }
    }

    /// How long until the strap alarm next buzzes, as "18 hours, 6 minutes", or nil when no alarm is set.
    ///
    /// A wall-clock time answers "when", but not "is that tonight or tomorrow", which is the question an
    /// alarm actually raises when you are looking at it in the evening. Resolved through the same
    /// `nextSmartAlarmDate` the strap is armed from, so a per-day override counts down to ITS time.
    ///
    /// `DateComponentsFormatter` rather than hand-built text because the unit words pluralise differently
    /// per language, and an app that ships nine of them should not be writing "1 hours".
    private func strapAlarmCountdown(from now: Date) -> String? {
        guard let next = nextStrapAlarm(from: now) else { return nil }
        let seconds = next.timeIntervalSince(now)
        // Under a minute there is no useful number left, and "in 0 minutes" reads like a bug.
        guard seconds >= 60 else { return String(localized: "Alarm in less than a minute") }
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var cal = Calendar.current
            cal.locale = AppLanguage.activeLocale
            return cal
        }()
        formatter.unitsStyle = .full
        // Days included because a weekday-restricted alarm can be up to a week out, and "151 hours" is
        // not an answer. Leading zero units are dropped, so a same-day alarm stays "18 hours, 6 minutes".
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        formatter.maximumUnitCount = 3
        guard let span = formatter.string(from: seconds), !span.isEmpty else { return nil }
        return String(localized: "Alarm in \(span)")
    }

    /// What a day with no override of its own actually does.
    ///
    /// There is no single fallback to show: the strap alarm falls back to its OWN time while the reminder
    /// falls back to the usual wake time above, and a row can only display one number. It displays the
    /// reminder's, so a day the alarm will fire at 10:00 can sit in this list reading 13:00. Naming both
    /// beats picking one and being wrong half the time. Hoisted out of the view body to keep this screen
    /// clear of the iOS type-check budget.
    ///
    /// Both base times are real settings, so `timeLabel` is right here and matches the "You'll be reminded
    /// around ..." line directly above. `nextStrapAlarmLabel` differs on purpose: it renders a weekday too,
    /// so it needs a date formatter regardless, and takes the reader's clock format while it is there.
    private var untouchedDayExplainer: String {
        guard behavior.smartAlarmEnabled else {
            return String(localized: "Days you leave alone use the usual wake time above.")
        }
        let alarm = timeLabel(behavior.smartAlarmMinutes)
        let usual = timeLabel(wakeMinutes)
        return String(localized: "Days you leave alone keep your strap alarm at \(alarm), and time the reminder from \(usual).")
    }

    /// One weekday's override row: the day name, the effective wake time (override or default), a picker to
    /// set it, and a clear control shown only when an override exists for that day.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.weekdayName(weekday))
                    .font(StrandFont.subhead)
                    .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                // Without this a row reading 13:00 looks like a decision someone made for that day,
                // when it is just the usual wake time showing through. The strap alarm may well fire
                // at a different hour on exactly these days.
                if !hasOverride {
                    Text("no time of its own")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: 120, alignment: .leading)
            Spacer(minLength: 0)
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                    // #1864: re-arm so clearing an override reverts that day's wake to the default time
                    // on the strap alarm + backup notification too, not just the wind-down nudge.
                    model.applySmartAlarm()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override, use the default wake time")
            }
            DatePicker("", selection: overrideBinding(weekday, effective: effective),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
        }
    }

    /// A binding for one weekday's wake override — reads the effective minute, writes a NEW override (a pick
    /// always sets that day's override) into both the store and the local mirror, rescheduling via the store.
    private func overrideBinding(_ weekday: Int, effective: Int) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = effective / 60
                c.minute = effective % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                WindDownNudge.setWakeOverride(weekday: weekday, minutes: m)
                overrides[weekday] = m
                // #1864: re-arm the strap alarm + backup notification so the new per-day time takes
                // effect immediately, not just the wind-down reminder. Without this the override moved
                // only the evening nudge and left the wake on the default time.
                model.applySmartAlarm()
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Strap alarm weekday picker (#766, moved here from Automations, behaviour intact)

    private var alarmWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { dow in
                    let selected = Self.alarmWeekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                    Text(Self.alarmWeekdayInitial(dow))
                        .font(StrandFont.caption)
                        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
                        .contentShape(Circle())
                        .onTapGesture { behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(dow, in: behavior.smartAlarmWeekdays) }
                        .accessibilityLabel(Self.weekdayName(dow))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bridges the strap alarm's minutes-since-midnight store to a DatePicker's Date.
    private var alarmTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = behavior.smartAlarmMinutes / 60
                c.minute = behavior.smartAlarmMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                behavior.smartAlarmMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }
        )
    }

    // The strap-alarm weekday rules: pure + nonisolated so they stay unit-testable. Kept byte-identical
    // to the originals in AutomationsView (only renamed with an `alarm` prefix to avoid colliding with
    // this view's full-name `weekdayName`).

    /// A day reads as "on" when the set is empty (= every day) or explicitly contains it.
    nonisolated static func alarmWeekdayIsSelected(_ dow: Int, in days: Set<Int>) -> Bool {
        days.isEmpty || days.contains(dow)
    }

    /// Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
    nonisolated static func alarmToggledWeekday(_ dow: Int, in days: Set<Int>) -> Set<Int> {
        var next: Set<Int>
        if days.isEmpty {
            next = Set(1...7)
            next.remove(dow)
        } else if days.contains(dow) {
            next = days
            next.remove(dow)
        } else {
            next = days
            next.insert(dow)
        }
        return next.count == 7 ? [] : next
    }

    /// Human-readable summary of the selection.
    nonisolated static func alarmWeekdaySummary(_ days: Set<Int>) -> String {
        if days.isEmpty || days.count == 7 { return String(localized: "Every day") }
        if days == Set(2...6) { return String(localized: "Weekdays") }
        if days == Set([1, 7]) { return String(localized: "Weekends") }
        return weekdayOrder.filter { days.contains($0) }.map { alarmWeekdayShort($0) }.joined(separator: ", ")
    }

    /// One-letter day chip. Derived from the localized short name so the initials follow the
    /// language (and Tue/Thu or Sat/Sun never share a single collision-prone key). English output
    /// is byte-identical to the old hardcoded initials.
    private static func alarmWeekdayInitial(_ dow: Int) -> String {
        let short = alarmWeekdayShort(dow)
        return short == "?" ? "?" : String(short.prefix(1))
    }

    nonisolated private static func alarmWeekdayShort(_ dow: Int) -> String {
        switch dow {
        case 1: return String(localized: "Sun")
        case 2: return String(localized: "Mon")
        case 3: return String(localized: "Tue")
        case 4: return String(localized: "Wed")
        case 5: return String(localized: "Thu")
        case 6: return String(localized: "Fri")
        case 7: return String(localized: "Sat")
        default: return "?"
        }
    }
}
