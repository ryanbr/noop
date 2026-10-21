import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Weekly plan card
//
// This week's progress toward the user's own sleep / Effort / steps goals. The counting rules live in the
// pure `WeeklyPlan` (StrandAnalytics; Kotlin twin com.noop.analytics.WeeklyPlan); this file only stores the
// user's goal day-counts, formats and renders. Mirrors the Android `WeeklyPlanCard.kt`.

/// Days per week for each goal. Same keys as the Android `WeeklyPlanPrefs`; not in .noopbak.
enum WeeklyPlanPrefs {
    static func key(_ kind: WeeklyPlanKind) -> String { "weeklyPlan.\(kind.rawValue)Days" }

    static func goals(_ defaults: UserDefaults = .standard) -> [WeeklyPlan.Goal] {
        WeeklyPlan.defaultGoals().map { g in
            var g = g
            if defaults.object(forKey: key(g.kind)) != nil {
                g.targetDays = min(7, max(0, defaults.integer(forKey: key(g.kind))))
            }
            return g
        }
    }
}

struct WeeklyPlanCard: View {
    let days: [DailyMetric]
    @State private var goals = WeeklyPlanPrefs.goals()

    var body: some View {
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let week = WeeklyPlan.week(days.map {
            WeeklyPlan.Day(day: $0.day, sleepMin: $0.totalSleepMin, strain: $0.strain, steps: $0.steps.map(Double.init))
        }, today: today, goals: goals)

        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("This week").strandOverline()
                Text("Weekly plan").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(goals.indices, id: \.self) { i in
                    goalRow(i, week?.progress.first { $0.goal.kind == goals[i].kind }, todayIndex: week?.todayIndex ?? 0)
                }
                Text("Your own goals, counted Monday to Sunday from this device's data.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func goalRow(_ i: Int, _ p: WeeklyPlan.Progress?, todayIndex: Int) -> some View {
        let goal = goals[i]
        let binding = Binding<Int>(
            get: { goals[i].targetDays },
            set: { v in
                goals[i].targetDays = min(7, max(0, v))
                UserDefaults.standard.set(goals[i].targetDays, forKey: WeeklyPlanPrefs.key(goal.kind))
            })
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Stepper(value: binding, in: 0...7) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(label(goal)).font(StrandFont.subhead).foregroundStyle(accent(goal.kind))
                    Text(status(goal, p)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if goal.targetDays > 0 {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(0..<7, id: \.self) { d in
                        let hit = p?.hitWeekdays.contains(d) == true
                        VStack(spacing: NoopMetrics.spaceHalf) {
                            Circle()
                                .fill(hit ? accent(goal.kind)
                                      : StrandPalette.textTertiary.opacity(d <= todayIndex ? 0.35 : 0.12))
                                .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                            Text(verbatim: weekdayLetter(d))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius))
    }

    private func label(_ g: WeeklyPlan.Goal) -> String {
        switch g.kind {
        case .sleep:
            let m = Int(g.threshold.rounded())
            return String(localized: "Sleep \(m / 60)h \(m % 60)m+")
        case .effort: return String(localized: "Effort \(Int(g.threshold))+")
        case .steps: return String(localized: "\(Int(g.threshold).formatted())+ steps")
        }
    }

    private func status(_ g: WeeklyPlan.Goal, _ p: WeeklyPlan.Progress?) -> String {
        guard g.targetDays > 0 else { return String(localized: "Off") }
        guard let p else { return "" }
        if p.met { return String(localized: "Done · \(p.daysHit) of \(g.targetDays) days") }
        if p.onTrack { return String(localized: "On track · \(p.daysHit) of \(g.targetDays) days") }
        return String(localized: "Out of reach this week · \(p.daysHit) of \(g.targetDays) days")
    }

    private func accent(_ k: WeeklyPlanKind) -> Color {
        k == .sleep ? StrandPalette.restColor : StrandPalette.effortColor
    }

    /// Narrow weekday symbol, Monday first.
    private func weekdayLetter(_ mondayIndex: Int) -> String {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols   // Sunday first
        return symbols[(mondayIndex + 1) % 7]
    }
}
