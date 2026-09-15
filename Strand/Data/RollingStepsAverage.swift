import Foundation
import SwiftUI
import StrandDesign
import WhoopStore

/// Calendar-day window, never 30 observed rows. Missing observations are not zero.
struct RollingStepsAverage: Equatable {
    let mean: Double?
    let observedDays: Int

    static func startDay(ending day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = formatter.date(from: day),
              let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
        return formatter.string(from: start)
    }

    static func calculate(readings: [(day: String, value: Double)], ending day: String) -> Self {
        guard let start = startDay(ending: day) else { return .init(mean: nil, observedDays: 0) }
        var byDay: [String: Double] = [:]
        for reading in readings where reading.day >= start && reading.day <= day
            && reading.value.isFinite && reading.value >= 0 {
            byDay[reading.day] = reading.value
        }
        return .init(mean: byDay.isEmpty ? nil : byDay.values.reduce(0, +) / Double(byDay.count),
                     observedDays: byDay.count)
    }
}

extension Repository {
    /// Shared by the detail and rolling tile: measured strap, phone import, then strap estimate.
    func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution {
        async let strap = resolvedSeries(key: "steps", source: Self.whoopSource, from: from, to: to)
        async let phone = resolvedSeries(key: "steps", source: "apple-health", from: from, to: to)
        async let estimate = resolvedSeries(key: "steps_est", source: Self.whoopSource, from: from, to: to)
        let resolutions = await [strap, phone, estimate]
        var byDay: [String: ResolvedMetricPoint] = [:]
        for resolution in resolutions {
            for point in resolution.points where byDay[point.day] == nil { byDay[point.day] = point }
        }
        return MetricSeriesResolution(requestedSource: Self.whoopSource,
                                      candidates: resolutions.flatMap(\.candidates),
                                      points: byDay.values.sorted { $0.day < $1.day })
    }
}

/// Loads only when explicitly enabled. Task identity follows the selected day and repository refresh.
struct RollingStepsAverageCard: View {
    let day: String
    @EnvironmentObject private var repo: Repository
    @State private var result: RollingStepsAverage?
    @State private var resultDay: String?

    var body: some View {
        let current = resultDay == day ? result : nil
        NavigationLink(value: TabRoute.metricSourced(key: "steps", source: MetricCatalog.combinedStepsSource)) {
            HStack(spacing: 12) {
                Image(systemName: DashboardCard.stepsAverage30.icon)
                    .foregroundStyle(StrandPalette.metricCyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DashboardCard.stepsAverage30.title)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(current.map { String(localized: "\($0.observedDays) of 30 days") } ?? "—")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Text(current?.mean.map { $0.formatted(.number.locale(AppLanguage.activeLocale).precision(.fractionLength(0))) } ?? "—")
                    .font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .background(NoopPanelSurface(tint: StrandPalette.metricCyan, cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .task(id: "\(day)|\(repo.refreshSeq)") {
            guard let start = RollingStepsAverage.startDay(ending: day) else { return }
            let readings = await repo.resolvedSteps(from: start, to: day)
            guard !Task.isCancelled else { return }
            result = RollingStepsAverage.calculate(readings: readings.values, ending: day)
            resultDay = day
        }
    }
}
