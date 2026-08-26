import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One resolved vital-sign tile: the latest value across the source precedence, banded against the
/// user's own trailing baseline (population fallback until 14 trusted nights), plus the day + source
/// that supplied it so the caption can name them honestly. The view layer reads only this — all of the
/// source resolution + banding lives in `BodyVitalSigns` so it stays pure and testable.
struct BodyVitalReading: Identifiable {
    let key: String
    let label: String
    let unit: String
    let value: Double?
    let format: (Double) -> String
    let banding: VitalBands.Result
    let metricColor: Color
    let day: String?
    let source: DailyMetricSource?
    let missingCaption: String
    /// Trailing values for this vital (oldest → newest), so the tile can draw a metric-tinted
    /// sparkline with a glowing "now" end-cap like Today's Key-Metrics tiles. Presentation-only:
    /// the resolved value, banding and source are unchanged — this is just the trend for the trail.
    /// Defaulted so existing call sites (previews/tests) keep compiling unchanged.
    var sparkline: [Double]? = nil
    /// #1118: an "unverified" caveat appended to the caption when the resolved value is present but the
    /// strap's own capture is known-unreliable for it (e.g. a WHOOP 4.0 R-R over-count contaminating HRV).
    /// nil = no caveat. Defaulted so existing call sites keep compiling unchanged.
    var caveat: String? = nil
    /// A second reading shown with the caption, under the headline value (#1636).
    ///
    /// Distinct from `caveat`, which says the value is unreliable; this one says what the value means.
    /// Skin temperature is the case: the absolute leads, and the deviation it was derived from is what
    /// makes it legible — "+0.2" says nothing without an anchor, and 34.6 °C says little without
    /// knowing it runs high for you. Pure formatted data (a number and a unit), never a sentence.
    /// Defaulted so existing call sites keep compiling unchanged.
    var secondary: String? = nil

    var id: String { key }

    var formattedValue: String? {
        value.map { "\(format($0)) \(unit)" }
    }

    /// Colour communicates state: in-range = the metric's category colour,
    /// out-of-range = warning amber, no data = tertiary.
    var accent: Color {
        switch banding.band {
        case .noData:     return StrandPalette.textTertiary
        case .inRange:    return metricColor
        case .outOfRange: return StrandPalette.statusWarning
        }
    }

    /// The tile caption: "<day> · <source> · <state>". Falls back to a metric-specific "no value"
    /// line when nothing resolved, so an empty tile still says why instead of a bare dash.
    var stateCaption: String {
        guard let day else { return missingCaption }
        // #1636: the secondary reading leads, so it sits directly under the headline value.
        var parts = secondary.map { [$0] } ?? []
        parts.append(Self.dayLabel(day))
        if let sourceText = Self.sourceLabel(source, key: key) {
            parts.append(sourceText)
        }
        parts.append(stateText)
        if let caveat { parts.append(caveat) }   // #1118: e.g. "unverified · over-reports R-R"
        return parts.joined(separator: " · ")
    }

    var accessibilityText: String {
        guard let v = formattedValue else { return String(localized: "\(label): no data") }
        return String(localized: "\(label): \(v), \(stateCaption)")
    }

    /// Which yardstick judged the value: your own baseline vs the typical adult range. String(localized:)
    /// — StatTile's caption is a plain String rendered via Text(String), which never consults the catalog.
    private var stateText: String {
        // Raw SpO₂ is a device-dependent ADC, not a clinical value — never claim an in/out-of-range
        // judgment. Show a plain "uncalibrated" note when a value decoded, "No data" otherwise. (#93)
        if key == "spo2raw" {
            return banding.band == .noData ? String(localized: "No data")
                                           : String(localized: "Uncalibrated")
        }
        switch (banding.band, banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In your range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical range")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }

    /// Short provenance word for the caption. The local-cache fallback stays unnamed (previews/tests),
    /// and computed skin temp reads "vs baseline" (#622) since that figure is a ±°C nightly deviation.
    private static func sourceLabel(_ source: DailyMetricSource?, key: String) -> String? {
        guard let source else { return nil }
        switch source {
        case .whoopImport:
            return String(localized: "WHOOP import")
        case .noopComputed:
            // Live pipeline stores ±°C vs personal baseline (#622) — not absolute wrist °C.
            if key == "skin" { return String(localized: "vs baseline") }
            return String(localized: "NOOP computed")
        case .appleHealth:
            return String(localized: "Apple Health")
        case .localCache:
            return nil
        }
    }

    static func dayLabel(_ day: String) -> String {
        if day == BodyVitalSigns.logicalDayKey(Date()) { return String(localized: "Today") }
        guard let date = BodyVitalSigns.dayParser.date(from: day) else { return day }
        return BodyVitalSigns.dayFormatter.string(from: date)
    }
}

/// Builds the body vital-sign readings from source-tagged daily rows. Pure + namespaced so the
/// resolution (per-metric source precedence) and banding can be unit-tested without a Repository.
enum BodyVitalSigns {
    /// Preview/test convenience: wrap plain rows (optionally a separate "today") as local-cache rows.
    static func readings(days: [DailyMetric],
                         today: DailyMetric?,
                         temperatureUnit: TemperatureUnit) -> [BodyVitalReading] {
        var sourceRows = days.map { SourcedDailyMetric(metric: $0, source: .localCache) }
        if let today, !days.contains(where: { $0.day == today.day }) {
            sourceRows.append(SourcedDailyMetric(metric: today, source: .localCache))
        }
        return readings(sourceRows: sourceRows, temperatureUnit: temperatureUnit)
    }

    static func readings(sourceRows: [SourcedDailyMetric],
                         temperatureUnit: TemperatureUnit,
                         now: Date = Date(),
                         spo2CandidateByDay: [String: Double] = [:],
                         hrvOverCountByDay: [String: Double] = [:]) -> [BodyVitalReading] {
        let logicalDay = logicalDayKey(now)

        // Resolve one metric to a per-day series, taking the FIRST source (by precedence) that carries
        // a value for each day — imported wins over computed wins over Apple, per `vitalPrecedence`.
        func points(key: String, _ value: (DailyMetric) -> Double?) -> [VitalPoint] {
            let allowedSources = DailyMetricSource.vitalPrecedence(for: key)
            var byDay: [String: VitalPoint] = [:]
            for source in allowedSources {
                for row in sourceRows where row.source == source {
                    guard let v = value(row.metric), byDay[row.metric.day] == nil else { continue }
                    byDay[row.metric.day] = VitalPoint(day: row.metric.day, value: v, source: row.source)
                }
            }
            return byDay.values.sorted { $0.day < $1.day }
        }

        // Prefer the logical day's value; otherwise the most recent day that has one — so a vital still
        // shows after a day with no wear instead of blanking to "—". That carry is STALENESS-BOUNDED
        // (`Baselines.vitalCarryDays`): it exists to survive a missed night, not to keep a months-old
        // reading under a section headed "Latest". Unbounded, `pts.last` reached back arbitrarily far —
        // a WHOOP CSV import that ended 30 Jul kept this tile reading "15.6 rpm" a fortnight later. The
        // "· 30 Jul ·" in `stateCaption` was not enough: the eye takes the headline number for today's.
        func latest(_ pts: [VitalPoint]) -> VitalPoint? {
            if let today = pts.last(where: { $0.day == logicalDay }) { return today }
            return Baselines.freshestCarried(pts.map { (day: $0.day, value: $0) },
                                             todayKey: logicalDay)?.value
        }

        func history(before day: String?, _ pts: [VitalPoint]) -> [Double?] {
            VitalBands.calendarSeries(pts.filter { point in
                guard let day else { return true }
                return point.day < day
            }.map { ($0.day, Optional($0.value)) })
        }

        let respPoints = points(key: "resp", \.respRateBpm)
        let spo2Points = points(key: "spo2", \.spo2Pct)
        // #103/queue-11a: SpO₂ candidate — WHOOP `spo2_candidate_82`, or an Oura owner's ceiling@100
        // `0x6F` mean (device-conditional, computed in IntelligenceEngine; this view just reads whatever
        // landed in metricSeries). When no calibrated spo2Pct exists AND the toggle is ON, the candidate
        // mean is passed in from metricSeries as a fallback. Neither candidate is a validated calibration
        // and both ship behind this one default-off toggle, never as `spo2Pct` (CLAUDE.md derived-
        // biosignal rule). Built into VitalPoints so the tile + sparkline + `latest()` resolve it the
        // same way.
        let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled && !spo2CandidateByDay.isEmpty
        let spo2CandidatePoints: [VitalPoint] = spo2CandidateOn
            ? spo2CandidateByDay.map { (day, value) in
                VitalPoint(day: day, value: value, source: .noopComputed)
            }.sorted { $0.day < $1.day }
            : []
        // WHOOP 4.0 raw SpO₂: the (red + IR) / 2 ADC mean per night, present only when both channels
        // decoded for the day. On-device only, so this resolves to the NOOP-computed row. (#93)
        let spo2rawPoints = points(key: "spo2raw") { m in
            guard let r = m.spo2Red, let i = m.spo2Ir else { return nil }
            return (Double(r) + Double(i)) / 2.0
        }
        let rhrPoints = points(key: "rhr") { $0.restingHr.map(Double.init) }
        let hrvPoints = points(key: "hrv", \.avgHrv)
        let skinPoints = points(key: "skin", \.skinTempDevC)
        // #1636: the night's ABSOLUTE, when the strap measured one. Nights scored before that column
        // shipped carry only the deviation and refill on the next scoring pass, so this is empty until
        // then and everything below falls through to the deviation-led behaviour unchanged.
        let skinAbsPoints = points(key: "skin", \.skinTempC)

        let respRow = latest(respPoints)
        // #103/queue-11a: fall back to the spo2_candidate mean when no calibrated spo2Pct exists. The
        // candidate is labelled "strap estimate (unverified)" in the tile caption so it is never read as
        // a calibrated blood-oxygen percentage.
        let spo2Row = latest(spo2Points) ?? latest(spo2CandidatePoints)
        let spo2IsCandidate = spo2Row != nil && latest(spo2Points) == nil
        let spo2rawRow = latest(spo2rawPoints)
        let rhrRow = latest(rhrPoints)
        let hrvRow = latest(hrvPoints)
        let skinRowDeviation = latest(skinPoints)
        // #1118: mark HRV "unverified" when this night's in-sleep R-R was over-counted — the WHOOP 4.0
        // two-optical-channel artifact that inflates R-R and contaminates RMSSD, so NOOP's HRV won't match
        // WHOOP until the de-dup fix lands. The flag is written only for NOOP's OWN measured capture (an
        // imported WHOOP-app night never sets it), so a pure-import night is never caveated. Gated on the
        // flag ALONE — no source check — to stay behaviourally identical to Android, whose DailyMetric
        // carries no per-row source (feature-level parity). (#1118)
        let hrvCaveat: String? = (hrvRow.map { (hrvOverCountByDay[$0.day] ?? 0) >= 0.5 } ?? false)
            ? String(localized: "unverified · over-reports R-R")
            : nil

        // Trailing values (oldest → newest) feeding each tile's sparkline trail. A 2+ point series
        // draws; the tile hides the trail otherwise. Presentation-only — built from the same resolved
        // points already used for the value, just kept as a series rather than collapsed to `latest`.
        func trail(_ pts: [VitalPoint], window: Int = 14) -> [Double] {
            pts.suffix(window).map(\.value)
        }

        // Skin temp is bimodal: CSV imports store ABSOLUTE °C, the on-device pipeline a ±°C DEVIATION —
        // partition the history to the displayed value's kind and pick the matching config + population
        // fallback (±0.6 °C mirrors the illness watch's flag threshold).
        //
        // #1636: resolve the DISPLAYED night first — the freshest that carries either reading — then
        // lead with its absolute if it has one. Asking "does the row I am already showing have an
        // absolute?" is what keeps the tile from silently stepping back to an older night: an
        // import-only night has a deviation and no absolute, and a CALIBRATING night has the reverse
        // (`recomputeSkinTempDev` returns nil until the baseline is usable, while the absolute is
        // already measured — those wearers read "needs ~4 worn nights" today with a real temperature
        // sitting unshown behind it).
        let skinAbsCandidate = latest(skinAbsPoints)
        let skinRowDay: String? = [skinRowDeviation?.day, skinAbsCandidate?.day].compactMap { $0 }.max()
        let skinAbsRow = skinAbsCandidate.flatMap { $0.day == skinRowDay ? $0 : nil }
        let skinRow = skinAbsRow ?? skinRowDeviation
        let skin = skinRow?.value
        let skinIsAbsolute = skinAbsRow != nil || (skin.map(VitalBands.isAbsoluteSkinTemp) ?? true)
        // The series the tile is actually showing — banding and the sparkline must both read from it, or
        // an absolute would be scored against a history of deviations (#1636).
        let skinSeries = skinAbsRow != nil ? skinAbsPoints : skinPoints
        let skinResult: VitalBands.Result
        if let skin {
            skinResult = VitalBands.band(
                value: skin,
                history: VitalBands.skinTempHistory(matching: skin, in: history(before: skinRow?.day, skinSeries)),
                populationRange: skinIsAbsolute ? 33...36 : (-0.6)...0.6,
                cfg: skinIsAbsolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg
            )
        } else {
            skinResult = VitalBands.Result(band: .noData, basis: .population, nights: 0)
        }

        // Resolve the skin-temp label + unit once (#622). Absolute → "Skin Temp" / "°C";
        // deviation → "Skin Temp Δ" / "Δ°C" so −0.1 is never read as a broken thermometer.
        let skinKind: SkinTempDisplay.Kind = skinIsAbsolute ? .absolute : .deviation
        let fahrenheit = temperatureUnit == .fahrenheit
        let skinUnitLabel = SkinTempDisplay.unitSymbol(kind: skinKind, fahrenheit: fahrenheit)
        let skinTitle = skinIsAbsolute
            ? String(localized: "Skin Temp")
            : String(localized: "Skin Temp Δ")
        let skinFormat: (Double) -> String = { c in
            SkinTempDisplay.numberString(c, kind: skinKind, fahrenheit: fahrenheit, decimals: 1)
        }
        // #1636: the deviation for THE DISPLAYED NIGHT — not the freshest one anywhere. A calibrating
        // night carries an absolute and no deviation, and reaching for the latest deviation there would
        // print a previous night's number under tonight's temperature.
        let skinSecondary: String? = skinAbsRow == nil ? nil
            : skinPoints.last(where: { $0.day == skinRow?.day }).map { dev in
                let n = SkinTempDisplay.numberString(dev.value, kind: .deviation,
                                                     fahrenheit: fahrenheit, decimals: 1)
                return "\(n) \(SkinTempDisplay.unitSymbol(kind: .deviation, fahrenheit: fahrenheit))"
            }

        return [
            BodyVitalReading(
                key: "resp",
                label: String(localized: "Resp Rate"),
                unit: "rpm",
                value: respRow?.value,
                format: { String(format: "%.1f", $0) },
                banding: VitalBands.band(
                    value: respRow?.value,
                    history: history(before: respRow?.day, respPoints),
                    populationRange: 12...20,
                    cfg: Baselines.respCfg
                ),
                metricColor: StrandPalette.metricCyan,
                day: respRow?.day,
                source: respRow?.source,
                missingCaption: String(localized: "No respiratory-rate value"),
                sparkline: trail(respPoints)
            ),
            BodyVitalReading(
                key: "spo2",
                label: String(localized: "Blood O₂"),
                unit: "%",
                value: spo2Row?.value,
                format: { String(format: "%.0f", $0) },
                // Population-only on purpose: an absolute <95% floor is meaningful regardless of
                // personal baseline (no "spo2" MetricCfg exists).
                banding: VitalBands.band(
                    value: spo2Row?.value,
                    history: [],
                    populationRange: 95...100,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2Row?.day,
                source: spo2Row?.source,
                // Two different empty states, and conflating them is what sends people to the forums. When
                // the night HAS raw red/IR counts, the strap's Blood-O₂ sensor plainly worked — only the
                // calibrated % is missing, because WHOOP derives it in their cloud and NOOP will not
                // fabricate one (spo2Pct is import-only; see Spo2ReTrace). Saying "No SpO₂ import or Health
                // value" there reads as "your sensor recorded nothing", next to a Raw SpO₂ tile showing a
                // live number.
                // The condition is EXACTLY the Raw SpO₂ tile's own value expression (`spo2rawRow`, below)
                // and must stay that way: the caption's claim is "the tile beside this one is showing a
                // number", so if the two drift, this says the sensor recorded on a night where the
                // neighbouring tile is blank. Note `latest()` here resolves `logicalDay ?? most recent`,
                // where Android resolves the selected day — so the ROW differs across platforms by design
                // and the parity contract is the relationship between the two tiles, not the row.
                missingCaption: spo2IsCandidate
                    ? String(localized: "strap estimate (unverified)")
                    : (PuffinExperiment.spo2CandidateDisplayEnabled && spo2Row == nil
                       ? String(localized: "toggle ON · no estimate yet")
                       : (spo2rawRow != nil
                          ? String(localized: "Raw counts only — needs an import")
                          : String(localized: "No SpO₂ import or Health value"))),
                sparkline: spo2IsCandidate ? trail(spo2CandidatePoints) : trail(spo2Points)
            ),
            BodyVitalReading(
                key: "spo2raw",
                label: String(localized: "Raw SpO₂"),
                unit: "ADC",
                value: spo2rawRow?.value,
                format: { String(format: "%.0f", $0) },
                // Unbanded on purpose: this is the WHOOP 4.0 raw PPG ADC mean, device/placement-dependent
                // with no clinical range — NOT a calibrated blood-oxygen %. Banding over the full u16 span
                // just keeps the tile cyan (never "off range") while `stateText` labels it uncalibrated, so
                // we never fabricate an in-range / out-of-range clinical judgment on raw sensor data. (#93)
                banding: VitalBands.band(
                    value: spo2rawRow?.value,
                    history: [],
                    populationRange: 0...65535,
                    cfg: nil
                ),
                metricColor: StrandPalette.metricCyan,
                day: spo2rawRow?.day,
                source: spo2rawRow?.source,
                missingCaption: String(localized: "No raw SpO₂ decode for the night"),
                sparkline: trail(spo2rawPoints)
            ),
            BodyVitalReading(
                key: "rhr",
                label: String(localized: "Resting HR"),
                unit: "bpm",
                value: rhrRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: rhrRow?.value,
                    history: history(before: rhrRow?.day, rhrPoints),
                    populationRange: 40...60,
                    cfg: Baselines.restingHRCfg
                ),
                metricColor: StrandPalette.metricRose,
                day: rhrRow?.day,
                source: rhrRow?.source,
                missingCaption: String(localized: "No resting HR value"),
                sparkline: trail(rhrPoints)
            ),
            BodyVitalReading(
                key: "hrv",
                label: String(localized: "HRV"),
                unit: "ms",
                value: hrvRow?.value,
                format: { String(Int($0.rounded())) },
                banding: VitalBands.band(
                    value: hrvRow?.value,
                    history: history(before: hrvRow?.day, hrvPoints),
                    populationRange: 40...120,
                    cfg: Baselines.hrvCfg
                ),
                metricColor: StrandPalette.metricPurple,
                day: hrvRow?.day,
                source: hrvRow?.source,
                missingCaption: String(localized: "No HRV value"),
                sparkline: trail(hrvPoints),
                caveat: hrvCaveat   // #1118
            ),
            BodyVitalReading(
                key: "skin",
                label: skinTitle,
                unit: skinUnitLabel,
                value: skin,
                format: skinFormat,
                banding: skinResult,
                metricColor: StrandPalette.metricAmber,
                day: skinRow?.day,
                source: skinRow?.source,
                // #548/#622: empty is often calibrating (needs ~4 nights for ±deviation) or import-less —
                // not a silent "broken sensor". Absolute °C still arrives via WHOOP CSV import.
                missingCaption: String(localized: "No nightly skin-temp yet — needs ~4 worn nights (or import a WHOOP CSV)"),
                // Keep the trail on the displayed value's kind — absolute °C and ±deviation must not
                // mix on one sparkline (matches the banding partition above).
                sparkline: trail(skinSeries.filter { VitalBands.isAbsoluteSkinTemp($0.value) == skinIsAbsolute }),
                // #1636: the deviation this absolute was derived from, shown beneath it. Only when the
                // headline IS the absolute — on a deviation-led tile it would just repeat the value.
                secondary: skinSecondary
            ),
        ]
    }

    /// The newest day any resolved reading was sourced from — drives the section's "Latest" trailing label.
    static func latestDayLabel(_ readings: [BodyVitalReading]) -> String? {
        readings.compactMap(\.day).max().map(BodyVitalReading.dayLabel)
    }

    /// The LOGICAL local day for `now` (rolls at 04:00 local). Self-contained so this helper stays pure
    /// and independent of the @MainActor Repository — same boundary, mirrored here for the readings build.
    static func logicalDayKey(_ now: Date, rolloverHour: Int = 4) -> String {
        localDayFormatter.string(from: now.addingTimeInterval(-Double(rolloverHour) * 3_600))
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()
}

private struct VitalPoint: Equatable {
    let day: String
    let value: Double
    let source: DailyMetricSource
}

private extension DailyMetricSource {
    /// Source precedence for a vital, highest first. Skin temp deliberately omits Apple Health — it
    /// has no 1:1 Apple equivalent for the strap's ±deviation reading, so an Apple absolute value must
    /// not stand in for it. localCache is always last (previews/tests).
    static func vitalPrecedence(for key: String) -> [DailyMetricSource] {
        switch key {
        case "skin":
            return [.whoopImport, .noopComputed, .localCache]
        default:
            return [.whoopImport, .noopComputed, .appleHealth, .localCache]
        }
    }
}
