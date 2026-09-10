import SwiftUI
import StrandDesign

// MARK: - Hosted cards (#today-hosted-cards)
//
// Cards that natively live in the Trends or Sleep tab, which the user can ALSO surface inside the Today
// tab via the Customise sheet — added, removed and reordered like "Your cards", while still appearing in
// their home tab (mirrored, not moved). The selection is display-only: nothing is computed or stored
// differently, this just decides which foreign cards Today additionally renders and in what order.
//
// The rawValues are ORIGIN-NAMESPACED (`sleep.*` / `trends.*`) so a hosted id is self-describing on the
// wire and routes to the right provider, and can never collide with a Today `DashboardCard` id. Keep them
// byte-identical to the Android `HostedCard` enum so a backup/restore reads the same Today composition on
// either OS — the selection rides `.noopbak` under the `today.hostedCards` key.

/// One card that can be hosted in Today from another tab. The rawValue is the stable persisted identifier
/// (origin-namespaced); keep it byte-identical to the Android `HostedCard`.
enum HostedCard: String, CaseIterable, Identifiable {
    /// Sleep tab · "Sleep marks" — the tap-to-log going-to-sleep / awake card. Self-contained (logging
    /// only, no model), the first card wired end-to-end.
    case sleepMarks = "sleep.sleepMarks"
    /// Sleep tab · "Asleep duration" — trailing-30-night sleep-hours trend (#today-hosted-cards P1).
    case asleepDuration = "sleep.asleepDuration"
    /// Sleep tab · "Stages vs typical" — last night's Deep/REM/Light vs the wearer's personal per-stage
    /// means (#today-hosted-cards). First of the SleepModel-backed sleep cards hosted in Today.
    case stagesVsTypical = "sleep.stagesVsTypical"
    /// Sleep tab · "Night detail" — the metric grid (Rest/Efficiency/Consistency/Hours vs Needed/
    /// Restorative/Respiratory/Sleep Debt) rendered from the wearer's `SleepModel` (#today-hosted-cards).
    /// Second of the SleepModel-backed sleep cards hosted in Today.
    case nightDetail = "sleep.nightDetail"
    /// Sleep tab · "Sleep-debt ledger" — the rolling 14-night running balance of (slept − personal
    /// need) rendered from the wearer's `SleepModel` (#today-hosted-cards). Third of the SleepModel-backed
    /// sleep cards hosted in Today.
    case sleepDebt = "sleep.sleepDebt"
    /// Sleep tab · "Stages" — a READ-ONLY latest-night stage chart + breakdown, window times and nap
    /// split, rendered from the wearer's `SleepModel` (#today-hosted-cards). Unlike the interactive Sleep
    /// tab hero, the Today host carries NO night navigation, NO wake-edit and NO nap add/edit/delete —
    /// the interaction stays on the Sleep tab; only the display is mirrored (`StagesCard`).
    case stages = "sleep.stages"
    /// Sleep tab · "Hours vs Needed" — the wearer's latest hours-slept-vs-personal-need percentage
    /// rendered from the shared `SleepModel` (#today-hosted-cards). The Sleep tab surfaces this metric
    /// only as a StatTile in the Night-detail grid; the Today host gives it a standalone card
    /// (`HoursVsNeededCard`) reading the SAME `hoursVsNeeded` metric, so the value can't diverge.
    case hoursVsNeeded = "sleep.hoursVsNeeded"
    /// Sleep tab · "Consistency" — the wearer's latest sleep-consistency percentage (bedtime-onset spread,
    /// honouring the imported-consistency preference) rendered from the shared `SleepModel`
    /// (#today-hosted-cards). The Sleep tab surfaces this metric only as a StatTile in the Night-detail
    /// grid; the Today host gives it a standalone card (`ConsistencyCard`) reading the SAME `consistency`
    /// metric, so the value can't diverge.
    case consistency = "sleep.consistency"
    /// Stress tab · "Stress through the day" — today's autonomic-load curve (#2040 follow-up). The
    /// first card hosted from a tab other than Sleep. Read-only like `stages`: the Stress tab keeps the
    /// interactive timeline, and the Today host mirrors only the display.
    ///
    /// The rawValue rides `.noopbak` under `today.hostedCards`, so it is byte-identical to the Android
    /// `HostedCard.STRESS_TODAY`.
    case stressToday = "stress.today"
    /// Trends tab · "HRV" — the trailing-month HRV trend (#today-hosted-cards). The three Trends-origin
    /// cards render the SAME `ChartCard` + `TrendChart` pair the tab draws, from the SAME resolved
    /// points, parameterised by which `DailyMetric` field they read.
    ///
    /// These rawValues ride `.noopbak` and are byte-identical to the Android `HostedCard` ids.
    case trendHRV = "trends.hrv"
    /// Trends tab · "Resting heart rate" — the trailing-month resting-HR trend.
    case trendRestingHR = "trends.restingHr"
    /// Trends tab · "Effort" — the trailing-month Effort trend, on the wearer's chosen scale (#268).
    case trendEffort = "trends.effort"

    var id: String { rawValue }

    /// The card's display label in the Customise editor — matches the Android `HostedCard.title`.
    var title: String {
        switch self {
        case .sleepMarks: return String(localized: "Sleep marks")
        case .asleepDuration: return String(localized: "Asleep duration")
        case .stagesVsTypical: return String(localized: "Stages vs typical")
        case .nightDetail: return String(localized: "Night detail")
        case .sleepDebt: return String(localized: "Sleep-debt ledger")
        case .stages: return String(localized: "Stages")
        case .hoursVsNeeded: return String(localized: "Hours vs Needed")
        case .consistency: return String(localized: "Consistency")
        case .stressToday: return String(localized: "Stress through the day")
        case .trendHRV: return String(localized: "Heart rate variability")
        case .trendRestingHR: return String(localized: "Resting heart rate")
        case .trendEffort: return String(localized: "Effort")
        }
    }

    /// The originating tab, shown as the editor subtitle so a hosted card reads as "from Sleep" / "from
    /// Trends". Matches the Android `HostedCard.origin`.
    var origin: String {
        switch self {
        case .sleepMarks, .asleepDuration, .stagesVsTypical, .nightDetail, .sleepDebt, .stages, .hoursVsNeeded, .consistency: return String(localized: "Sleep")
        case .stressToday: return String(localized: "Stress")
        case .trendHRV, .trendRestingHR, .trendEffort: return String(localized: "Trends")
        }
    }

    /// Where tapping this card sends you: back to the tab it is a copy of.
    ///
    /// Declared on the CARD rather than inside the view that draws it, so it can be tested. A mapping
    /// that lives as a private method on a `View` is unreachable from any test, and a card quietly
    /// routing to the wrong tab is not the kind of thing anyone notices in review.
    ///
    /// `nil` for `sleepMarks`: it is the tap-to-log card, its buttons ARE its purpose, and wrapping it
    /// in a navigation target would put a second meaning behind the same press.
    ///
    /// Listed rather than defaulted, so a card added later cannot silently inherit "opens Sleep": the
    /// compiler asks where the new one goes.
    var route: TabRoute? {
        switch self {
        case .sleepMarks: return nil
        case .asleepDuration, .stagesVsTypical, .nightDetail, .sleepDebt, .stages,
             .hoursVsNeeded, .consistency: return .sleep
        case .stressToday: return .stress
        // The METRIC's own detail page rather than the Trends tab: closer to what was tapped, and the
        // destination the Charge and Effort key tiles already use. Twin of the Kotlin `Metric` destination.
        case .trendHRV: return .metricSourced(key: "hrv", source: "my-whoop")
        case .trendRestingHR: return .metricSourced(key: "rhr", source: "my-whoop")
        case .trendEffort: return .metricSourced(key: "strain", source: "my-whoop")
        }
    }

    /// SF Symbol for the editor row (reuses the shared customization-icon treatment).
    var customizationIcon: String {
        switch self {
        case .sleepMarks: return "moon.zzz"
        case .asleepDuration: return "chart.bar.xaxis"
        case .stagesVsTypical: return "chart.bar.doc.horizontal"
        case .nightDetail: return "square.grid.2x2"
        case .sleepDebt: return "scalemass"
        case .stages: return "chart.bar.fill"
        case .hoursVsNeeded: return "gauge.medium"
        case .consistency: return "repeat"
        case .stressToday: return "chart.xyaxis.line"
        case .trendHRV: return "waveform.path.ecg"
        case .trendRestingHR: return "heart"
        case .trendEffort: return "bolt.fill"
        }
    }

    /// Editor row tint.
    var customizationTint: Color {
        switch self {
        case .sleepMarks, .asleepDuration, .stagesVsTypical, .nightDetail, .sleepDebt, .stages, .hoursVsNeeded, .consistency: return StrandPalette.restColor
        case .stressToday: return StrandPalette.stressColor
        case .trendHRV: return StrandPalette.metricPurple
        case .trendRestingHR: return StrandPalette.metricRose
        case .trendEffort: return StrandPalette.effortColor
        }
    }

    /// The default selection: EMPTY. Nothing is hosted until the user opts in. On the enum (not the prefs)
    /// to mirror `DashboardCard.defaultSelection`; keep byte-identical to the Android companion default.
    static let defaultSelection: [HostedCard] = []

    /// Canonical order used to list the not-yet-hosted remainder in the editor (mirrors `allCases`).
    static let canonicalOrder: [HostedCard] = allCases
}

/// Display-only persistence for the Today-hosted card selection. Holds an ORDERED list of the enabled
/// hosted cards as a JSON-encoded [String] of ids; a card not in the list is not hosted. Stored in
/// @AppStorage("today.hostedCards") and whitelisted into `.noopbak`. Mirrors `DashboardCardPrefs`
/// byte-for-byte EXCEPT the default is EMPTY — hosting is purely additive/opt-in, so a fresh install
/// (and every existing user) hosts nothing until they add a card in Customise.
enum HostedCardPrefs {
    /// UserDefaults key — a JSON array of `HostedCard` ids in display order. In the `.noopbak` whitelist.
    static let selectionKey = "today.hostedCards"

    /// Encode an ordered list of hosted cards into the stored JSON string. Falls back to a comma-joined
    /// string if JSON encoding ever fails (it won't for [String]), so the value is always decodable.
    static func encode(_ cards: [HostedCard]) -> String {
        let ids = cards.map(\.rawValue)
        if let data = try? JSONEncoder().encode(ids), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return ids.joined(separator: ",")
    }

    /// Decode the stored string into an ordered list of hosted cards. An empty/unset string yields the
    /// EMPTY default (nothing hosted). Accepts both the JSON-array form and a legacy comma-joined form.
    /// Unknown ids are dropped; duplicates are de-duped; returns ONLY the hosted cards in their saved
    /// order. Unlike `DashboardCardPrefs`, an all-unknown decode stays EMPTY (never back-fills a default),
    /// because there is no sensible non-empty default for an opt-in surface.
    static func decodeEnabled(_ raw: String) -> [HostedCard] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return HostedCard.defaultSelection }

        let ids: [String]
        if let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        var seen = Set<HostedCard>()
        var result: [HostedCard] = []
        for token in ids {
            if let c = HostedCard(rawValue: token), seen.insert(c).inserted {
                result.append(c)
            }
        }
        return result
    }
}
