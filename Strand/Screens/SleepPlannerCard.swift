import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep planner card
//
// Tonight's sleep target at three goals (70 / 85 / 100 % of tonight's need), the time in bed each one takes
// at the user's typical efficiency, and the bedtime that implies for the next wake. The arithmetic lives in
// the pure `SleepPlanner` (StrandAnalytics; Kotlin twin com.noop.analytics.SleepPlanner); this file only
// resolves the wake time and renders. Mirrors the Android `SleepPlannerCard`. Display-only.

/// Where the planner's wake time came from, so the card can say so instead of hiding it.
enum PlannerWakeSource { case alarm, lastNight, fallback }

struct SleepPlannerCard: View {
    let model: SleepModel
    /// Asleep minutes in today's naps (outside the main night).
    let napMinToday: Double
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore

    static let defaultWakeMinute = 7 * 60

    var body: some View {
        let wake = resolvedWake()
        let plan = SleepPlanner.plan(
            nights: repo.days.map { (day: $0.day, asleepMin: $0.totalSleepMin, efficiency: $0.efficiency) },
            baseNeedMin: baseNeedMin,
            debtMin: model.sleepDebt.latest ?? 0,
            napMinToday: napMinToday,
            wakeMinuteOfDay: wake.minute)

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep planner", overline: "Tonight")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    if let plan {
                        breakdown(plan)
                        Divider()
                        Text(wakeLine(wake))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        ForEach(plan.tiers, id: \.goal) { tierRow($0) }
                        Text(plan.efficiencyUsed < 1.0
                             ? String(localized: "A planning guide, not a score. Time in bed assumes your typical \(Int(plan.efficiencyUsed * 100))% sleep efficiency.")
                             : String(localized: "A planning guide, not a score. No efficiency history yet, so time in bed equals the sleep target."))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text("Needs three nights in a row with sleep before it can plan tonight.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The same need the Hours-vs-Needed tile measures against: the imported figure for the newest night,
    /// else the engine's personalised need.
    private var baseNeedMin: Double {
        let newest = repo.days.last(where: { ($0.totalSleepMin ?? 0) > 0 })?.day
        return newest.flatMap { repo.importedSleep[$0]?.needMin } ?? SleepModel.debtNeedMin(days: repo.days)
    }

    /// The armed alarm's next fire (the same `nextSmartAlarmDate` the strap is armed from), else last
    /// night's wake, else 07:00.
    private func resolvedWake() -> (minute: Int, source: PlannerWakeSource) {
        let cal = Calendar.current
        if behavior.smartAlarmEnabled,
           let next = AppModel.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                                  weekdays: behavior.smartAlarmWeekdays,
                                                  overrides: WindDownNudge.perDayWakeOverrides) {
            let c = cal.dateComponents([.hour, .minute], from: next)
            return ((c.hour ?? 7) * 60 + (c.minute ?? 0), .alarm)
        }
        let end = Date(timeIntervalSince1970: TimeInterval(model.night.session.endTs))
        let c = cal.dateComponents([.hour, .minute], from: end)
        if let h = c.hour, let m = c.minute { return (h * 60 + m, .lastNight) }
        return (Self.defaultWakeMinute, .fallback)
    }

    private func wakeLine(_ wake: (minute: Int, source: PlannerWakeSource)) -> String {
        let t = clock(wake.minute)
        switch wake.source {
        case .alarm:     return String(localized: "Wake \(t) · from your alarm")
        case .lastNight: return String(localized: "Wake \(t) · from last night")
        case .fallback:  return String(localized: "Wake \(t) · no alarm or recent wake yet")
        }
    }

    private func breakdown(_ plan: SleepPlan) -> some View {
        HStack(alignment: .top) {
            cell(String(localized: "Base"), durationText(Double(plan.baseNeedMin)))
            cell(String(localized: "Debt"), "+" + durationText(Double(plan.debtMin)))
            cell(String(localized: "Naps"), "−" + durationText(Double(plan.napCreditMin)))
            cell(String(localized: "Tonight"), durationText(Double(plan.tonightNeedMin)))
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(label).strandOverline()
            Text(verbatim: value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tierRow(_ tier: SleepPlanTier) -> some View {
        let (label, color): (String, Color) = {
            switch tier.goal {
            case .minimum: return (String(localized: "Minimum"), StrandPalette.restDeep)
            case .solid:   return (String(localized: "Solid"), StrandPalette.restColor)
            case .full:    return (String(localized: "Full"), StrandPalette.restBright)
            }
        }()
        let pct = Int(tier.goal.fraction * 100)
        return HStack {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(label).font(StrandFont.headline).foregroundStyle(color)
                Text("\(pct)% of need · \(durationText(Double(tier.sleepTargetMin))) asleep · \(durationText(Double(tier.timeInBedMin))) in bed")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                Text("Bed by").strandOverline()
                Text(verbatim: clock(tier.bedtimeMinuteOfDay))
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(StrandPalette.surfaceInset, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func clock(_ minuteOfDay: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60,
                                         second: 0, of: Date()) ?? Date()
        return AppClock.hourMinuteFormatter().string(from: date)
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`).
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}
