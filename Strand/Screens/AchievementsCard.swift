import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Milestones card
//
// Milestones unlocked from the user's own daily history. The rules live in the pure `Achievements`
// (StrandAnalytics; Kotlin twin com.noop.analytics.Achievements); this file only formats and renders.
// Mirrors the Android `AchievementsCard.kt`.

struct AchievementsCard: View {
    let days: [DailyMetric]

    var body: some View {
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let list = Achievements.evaluate(days.map {
            Achievements.Day(day: $0.day, recovery: $0.recovery, strain: $0.strain, sleepMin: $0.totalSleepMin,
                             steps: $0.steps.map(Double.init))
        }, today: today)
        let unlocked = list.filter { $0.unlockedDay != nil }.count

        NoopCard(tint: StrandPalette.gold) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("\(unlocked) of \(list.count) unlocked").strandOverline()
                Text("Milestones").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(list, id: \.id) { a in
                    let on = a.unlockedDay != nil
                    HStack(spacing: NoopMetrics.space2) {
                        Circle()
                            .fill(on ? StrandPalette.gold : StrandPalette.textTertiary.opacity(0.2))
                            .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                        Text(label(a.id))
                            .font(StrandFont.subhead)
                            .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        Spacer(minLength: NoopMetrics.space2)
                        if a.isNew { Text("NEW").strandOverline().foregroundStyle(StrandPalette.gold) }
                        Text(verbatim: a.unlockedDay.map(dayText) ?? String(localized: "Locked"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, NoopMetrics.space2)
                    .background(StrandPalette.surfaceInset, in: Capsule())
                    .accessibilityElement(children: .combine)
                }
                Text("Unlocked from your own history on this device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func label(_ id: AchievementId) -> String {
        switch id {
        case .firstScore: return String(localized: "First scored day")
        case .streak7:    return String(localized: "7-day streak")
        case .streak30:   return String(localized: "30-day streak")
        case .scored100:  return String(localized: "100 scored days")
        case .charge90:   return String(localized: "Charge 90%+")
        case .sleep8h:    return String(localized: "8 hours asleep")
        case .effort18:   return String(localized: "Effort 18+")
        case .steps10k:   return String(localized: "10,000 steps")
        }
    }

    private func dayText(_ key: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
