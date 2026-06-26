import SwiftUI
import StrandDesign

/// Smart alarm (#207) — the iOS/macOS surface, and the single home for every alarm setting (#766).
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD PHONE wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this platform
/// deliberately does NOT offer a phone wake alarm. The dependable phone wake lives on Android, which has
/// the exact-alarm primitive. What we DO offer here: the strap's own firmware alarm (an on-wrist buzz that
/// works offline) and the cross-platform WIND-DOWN nudge. The strap firmware alarm moved here from the
/// Automations screen (#766) so both alarms live in one place rather than reading as duplicate entries.
struct SmartAlarmView: View {
    // #766: the strap firmware alarm reads/writes these via the shared BehaviorStore; AppModel.applySmartAlarm()
    // re-arms the strap on change. Injected app-wide in StrandApp, exactly as AutomationsView consumes them.
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    @State private var windDownOn = WindDownNudge.isEnabled
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        ScreenScaffold(title: "Smart alarm",
                       subtitle: "Your strap's offline wake buzz and a gentle evening wind-down nudge, in one place.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                windowHero
                honestyCard
                strapAlarmCard
                windDownCard
            }
        }
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
                    heroTime(label: "Wake",
                             time: timeLabel(wakeMinutes),
                             tint: StrandPalette.restBright)
                    Spacer(minLength: 0)
                }
                Text(windDownOn
                     ? "A calm nudge \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before your wake time."
                     : "Turn on the wind-down reminder below to land at your wake time rested.")
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

    // The up-front, honest explanation of why iOS gets a nudge and not a wake alarm.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No phone wake alarm on this device")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A sideloaded app can't sound a reliable wake alarm in the background on iOS — that needs a critical-alert permission this build doesn't have. The strap's own firmware alarm below can buzz your wrist instead, or use your phone's built-in Clock alarm. NOOP's smart wake (light-sleep detection) is available on the Android app.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Strap firmware alarm (#51), relocated here from AutomationsView (#766)

    /// The strap's OWN firmware alarm: arms the strap to buzz the wrist at a fixed wake time, fully offline
    /// (works with NOOP closed / Bluetooth asleep). Since iOS has no phone wake alarm (see honestyCard), this
    /// is the only wake mechanism on this platform. Content mirrors the card that used to live in Automations,
    /// re-skinned to this screen's StrandCard idiom; the BehaviorStore wiring + applySmartAlarm() are unchanged.
    private var strapAlarmCard: some View {
        StrandCard(padding: 20, tint: behavior.smartAlarmEnabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "alarm.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Strap firmware alarm")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("Wake to a buzz from the strap's own firmware alarm, even if NOOP is closed. Still experimental on WHOOP 4.0, so keep a backup alarm until you've confirmed it wakes you.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable strap alarm")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Arms the strap to buzz at your wake time.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $behavior.smartAlarmEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Enable strap alarm")
                }
                .frame(minHeight: 42)

                if behavior.smartAlarmEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Wake at").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: strapAlarmTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.compact)
                            .accessibilityLabel("Strap alarm wake time")
                    }
                    Divider().overlay(StrandPalette.hairline)
                    strapAlarmWeekdayPicker
                    Text("Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. We send the same alarm command the official app sends, but a strap-driven wake-up hasn't been confirmed on our side yet, so please keep a backup alarm for now.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmWeekdays) { _ in model.applySmartAlarm() }
        }
    }

    /// Which days the strap alarm fires on. Reuses the shared, unit-tested selection logic on AutomationsView
    /// (empty set = every day); the day initials/names + ordering are this view's own.
    private var strapAlarmWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { dow in
                    let selected = AutomationsView.weekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                    Text(Self.weekdayInitial(dow))
                        .font(StrandFont.caption)
                        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
                        .contentShape(Circle())
                        .onTapGesture { behavior.smartAlarmWeekdays = AutomationsView.toggledWeekday(dow, in: behavior.smartAlarmWeekdays) }
                        .accessibilityLabel(Self.weekdayName(dow))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(AutomationsView.weekdaySummary(behavior.smartAlarmWeekdays))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    /// Bridges the strap alarm's minutes-since-midnight store to a DatePicker's Date.
    private var strapAlarmTimeBinding: Binding<Date> {
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

    /// Single-letter weekday initial for the picker circles (Sun…Sat = 1…7).
    private static func weekdayInitial(_ dow: Int) -> String {
        switch dow {
        case 1: return "S"
        case 2: return "M"
        case 3: return "T"
        case 4: return "W"
        case 5: return "T"
        case 6: return "F"
        case 7: return "S"
        default: return "?"
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
                        .onChangeCompat(of: windDownOn) { on in WindDownNudge.setEnabled(on) }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Wake time")
                    }
                    Text("You'll be reminded around \(timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)

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
                Text("Set a wake time for specific days — a lie-in at the weekend, say. Days you leave alone use the time above.")
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
        }
    }

    /// One weekday's override row: the day name, the effective wake time (override or default), a picker to
    /// set it, and a clear control shown only when an override exists for that day.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return HStack(spacing: 12) {
            Text(Self.weekdayName(weekday))
                .font(StrandFont.subhead)
                .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
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
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (1...7).contains(dow) ? names[dow - 1] : "Day \(dow)"
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
}
