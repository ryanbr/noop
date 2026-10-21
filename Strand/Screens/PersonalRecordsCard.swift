import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Personal bests card
//
// All-time bests from the user's own daily history (best HRV, lowest resting HR, best Charge, longest sleep,
// ...), each with the day it was set and a NEW tag when it fell in the last week. The selection rules live in
// the pure `PersonalRecords` (StrandAnalytics; Kotlin twin com.noop.analytics.PersonalRecords); this file only
// formats and renders. Mirrors the Android `PersonalRecordsCard`. Display-only.

struct PersonalRecordsCard: View {
    let days: [DailyMetric]

    var body: some View {
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let records = PersonalRecords.records(days.map {
            PersonalRecords.Day(day: $0.day, hrvMs: $0.avgHrv, restingHr: $0.restingHr.map(Double.init),
                                recovery: $0.recovery, strain: $0.strain, sleepMin: $0.totalSleepMin,
                                efficiency: $0.efficiency, deepMin: $0.deepMin, remMin: $0.remMin,
                                steps: $0.steps.map(Double.init))
        }, today: today)

        NoopCard(tint: StrandPalette.gold) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("All time").strandOverline()
                Text("Personal bests")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if records.isEmpty {
                    Text("Records appear once NOOP has scored a few days.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(records, id: \.metric) { row($0) }
                    Text("From your own history on this device. Implausible readings never count as a record.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func row(_ r: PersonalRecords.Record) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                HStack(spacing: NoopMetrics.space2) {
                    Text(label(r.metric))
                        .font(StrandFont.subhead)
                        .foregroundStyle(accent(r.metric))
                    if r.isNew {
                        Text("NEW").strandOverline().foregroundStyle(StrandPalette.gold)
                    }
                }
                Text(verbatim: dayText(r.day))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                Text(verbatim: valueText(r.metric, r.value))
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let prev = r.previousBest {
                    Text("was \(valueText(r.metric, prev))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(StrandPalette.surfaceInset, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func label(_ m: PersonalRecordMetric) -> String {
        switch m {
        case .hrv:        return String(localized: "HRV")
        case .restingHr:  return String(localized: "Resting HR")
        case .recovery:   return String(localized: "Charge")
        case .strain:     return String(localized: "Highest Effort")
        case .sleep:      return String(localized: "Longest sleep")
        case .efficiency: return String(localized: "Sleep efficiency")
        case .deepSleep:  return String(localized: "Deep sleep")
        case .remSleep:   return String(localized: "REM sleep")
        case .steps:      return String(localized: "Steps")
        }
    }

    /// The score family a metric belongs to, so each row carries its family colour.
    private func accent(_ m: PersonalRecordMetric) -> Color {
        switch m {
        case .hrv, .restingHr, .recovery: return StrandPalette.chargeColor
        case .strain, .steps: return StrandPalette.effortColor
        case .sleep, .efficiency, .deepSleep, .remSleep: return StrandPalette.restColor
        }
    }

    /// The value in its own unit, matching the Android `personalRecordValueText`.
    private func valueText(_ m: PersonalRecordMetric, _ v: Double) -> String {
        switch m {
        case .hrv:        return String(format: "%.0f ms", v)
        case .restingHr:  return String(format: "%.0f bpm", v)
        case .recovery:   return String(format: "%.0f%%", v)
        case .strain:     return String(format: "%.1f", v)
        case .efficiency: return String(format: "%.0f%%", v * 100)
        case .sleep, .deepSleep, .remSleep:
            let m = Swift.max(0, Int(v.rounded()))
            return m < 60 ? String(localized: "\(m)m") : String(localized: "\(m / 60)h \(m % 60)m")
        case .steps:      return v.formatted(.number.precision(.fractionLength(0)))
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
