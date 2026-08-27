import Foundation
import StrandAnalytics

// MARK: - Unit system preference
//
// NOOP stores EVERYTHING in SI (km, kg, cm, °C) — the importers normalise on the way in, so this is a
// purely cosmetic, display-only layer. There is no data migration and nothing on disk changes when the
// user flips this. We keep one Metric/Imperial switch for length+mass with a SEPARATE temperature
// override, because plenty of people think in kg/cm but still read body temperature in °F (and vice
// versa). Default is Metric — most of the world, and it matches what we store.
//
// Persisted via @AppStorage (UserDefaults), the same mechanism every other macOS NOOP preference uses.
// The Android side mirrors this exactly in Units.kt + NoopPrefs.

/// The length+mass unit system. Temperature has its own override (see `UnitPrefs.temperature`).
enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial
    var id: String { rawValue }

    /// "follow the system" pairs temperature with the length/mass choice; an explicit case lets the
    /// user pin °C or °F independently of whether distances are in km or miles.
    var temperatureMatching: TemperatureUnit { self == .imperial ? .fahrenheit : .celsius }
}

/// Temperature display unit. Kept separate from `UnitSystem` so it can be overridden on its own.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit
    var id: String { rawValue }
}

/// How the Effort score is displayed (#268). NOOP's Effort is stored 0–100 (StrainScorer.maxStrain = 100);
/// people coming from WHOOP often think in its 0–21 Day Strain axis, so this purely cosmetic toggle lets
/// the SAME stored value be shown on either scale. Default is NOOP's own 0–100 — the data never changes.
enum EffortScale: String, CaseIterable, Identifiable {
    /// NOOP's native 0–100 axis (the stored value, one decimal).
    case hundred
    /// WHOOP's 0–21 Day Strain axis — the stored 0–100 value rescaled down for display only.
    case whoop
    var id: String { rawValue }
}

/// How the trend charts (Trends tab) are drawn — a purely cosmetic, display-only toggle. The plotted
/// data is identical on both settings; only the mark geometry changes (gradient line + area vs vertical
/// bars). Default is the classic line. Distinct from `ChartStyle`, which chooses the colour ramp; this
/// chooses line-vs-bar. Mirrored on Android by NoopPrefs("trend.chart.style").
enum TrendChartStyle: String, CaseIterable, Identifiable {
    /// The classic gradient-stroked line with a soft area fill (the long-standing look).
    case line
    /// Vertical bars from the axis baseline, one per sample, value-ramp filled.
    case bar
    var id: String { rawValue }
    /// Segmented-control label.
    var label: String { self == .bar ? "Bars" : "Line" }
}

/// Which sleep window the nightly HRV is measured over (#141). NOOP historically averages RMSSD across the
/// WHOLE night (every stage); WHOOP/Polar/etc. sample the last slow-wave-sleep window, which reads lower.
/// This lets a user match that. It CHANGES the computed avgHrv (NOT display-only), so a switch re-scores +
/// re-baselines. Default is the historical whole-night value. Mirrored on Android by NoopPrefs("hrv.window").
enum HrvWindow: String, CaseIterable, Identifiable {
    /// RMSSD averaged over every 5-min window of the night (NOOP's long-standing value).
    case whole
    /// RMSSD over DEEP (slow-wave) sleep windows only — the window WHOOP samples.
    ///
    /// "Comparable to WHOOP" describes the METHOD, not the accuracy of the resulting number: the deep
    /// windows come from NOOP's own stager, not the strap. `Tools/SleepPSG` scores that stager against
    /// PSG truth over 31 subjects / 26 773 epochs and measures deep at 18.94 % predicted vs 13.76 %
    /// truth — a +5.18 pp bias, roughly 38 % more deep epochs than exist, at four-class kappa 0.356.
    /// An over-inclusive deep window pulls this value back toward the whole-night mean, which is the
    /// one thing the setting exists not to be.
    ///
    /// So this stays opt-in and `whole` stays the default. #1008 tracks moving it, gated on that bias
    /// coming down; re-run the benchmark before changing the default rather than assuming it has.
    case deep
    var id: String { rawValue }
    /// Segmented-control label.
    var label: String { self == .deep ? "Deep sleep" : "Whole night" }
}

/// UserDefaults keys for the two unit preferences. Public-ish (internal) so `SettingsView`'s
/// `@AppStorage(UnitPrefs.systemKey)` and the formatter read the SAME key — no drift.
enum UnitPrefs {
    static let systemKey = "units.system"
    /// Temperature override. Empty string = "match the length/mass system" (the default).
    static let temperatureKey = "units.temperature"
    /// Effort display scale (#268). Stored raw is an `EffortScale` rawValue; an unset/unknown value
    /// resolves to `.hundred` (NOOP's native axis). Mirrored on Android by NoopPrefs("effort.scale").
    static let effortScaleKey = "effort.scale"

    /// Trend chart style (line vs bar). Stored raw is a `TrendChartStyle` rawValue; an unset/unknown
    /// value resolves to `.line` (the classic look). Display-only — the plotted data never changes.
    /// Mirrored on Android by NoopPrefs("trend.chart.style").
    static let trendChartStyleKey = "trend.chart.style"

    /// Nightly-HRV window (#141). Stored raw is an `HrvWindow` rawValue; unset/unknown resolves to `.whole`
    /// (the historical whole-night value). NOT display-only — it changes the computed avgHrv, so the engine
    /// reads it and a Settings switch re-scores. Mirrored on Android by NoopPrefs("hrv.window").
    static let hrvWindowKey = "hrv.window"

    /// Display factor for the #268 Effort scale: the stored 0-100 value multiplied by this renders on
    /// the user's chosen axis (1.0 for the native 0-100, 0.21 for the WHOOP-style 0-21). Display-only,
    /// mirrors Android's effortDisplayFactor helper so digest sentences match the charts on both.
    static func currentEffortDisplayFactor() -> Double {
        let raw = UserDefaults.standard.string(forKey: effortScaleKey) ?? ""
        return raw == EffortScale.whoop.rawValue ? 0.21 : 1.0
    }

    /// Whether the live-HR Live Activity (Lock Screen + Dynamic Island) may show, iOS only (#336).
    /// Defaults to ON. The user can turn it off in Notifications settings without digging into iOS
    /// Settings — `liveActivityEnabled()` reads it default-true so an unset key keeps the old behaviour.
    static let liveActivityKey = "liveActivity.enabled"
    static func liveActivityEnabled() -> Bool {
        UserDefaults.standard.object(forKey: liveActivityKey) == nil
            ? true : UserDefaults.standard.bool(forKey: liveActivityKey)
    }

    /// Resolve the stored raw values into a concrete temperature unit, applying the
    /// "match the system" default when no explicit override is set.
    static func resolveTemperature(system: UnitSystem, override raw: String) -> TemperatureUnit {
        if let explicit = TemperatureUnit(rawValue: raw) { return explicit }
        return system.temperatureMatching
    }

    /// Resolve the stored Effort-scale raw value, defaulting to NOOP's native 0–100 axis.
    static func resolveEffortScale(_ raw: String) -> EffortScale {
        EffortScale(rawValue: raw) ?? .hundred
    }
}

// MARK: - Pure conversion + formatting

/// Pure, dependency-free unit conversion and display formatting. Every site that prints a distance,
/// mass, height or temperature goes through here so a unit toggle reaches all of them at once.
///
/// The conversion factors are pinned by `UnitFormatterTests` — a wrong factor can't ship silently.
/// Nothing here reads UserDefaults: callers pass the resolved `UnitSystem` / `TemperatureUnit` in, which
/// keeps the formatter trivially testable and side-effect free.
enum UnitFormatter {

    // MARK: Factors (single source of truth — tests pin these exact numbers)

    /// 1 kilometre = 0.621371 miles.
    static let milesPerKilometer = 0.621371
    /// 1 kilogram = 2.20462 pounds.
    static let poundsPerKilogram = 2.20462
    /// 1 inch = 2.54 cm exactly → 1 cm = 1/2.54 inches.
    static let centimetersPerInch = 2.54

    // MARK: Distance (stored km)

    /// km → miles.
    static func kmToMiles(_ km: Double) -> Double { km * milesPerKilometer }

    /// Format a distance given in METRES (the stored unit for workout distance).
    /// Metric: "1.2 km" / "850 m". Imperial: "0.7 mi" / "230 yd" for sub-mile distances.
    static func distanceFromMeters(_ meters: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            let km = meters / 1000.0
            return km >= 1 ? oneDecimal(km) + " km" : "\(Int(meters.rounded())) m"
        case .imperial:
            let miles = kmToMiles(meters / 1000.0)
            if miles >= 0.1 { return oneDecimal(miles) + " mi" }
            // Below ~160 m show yards rather than a "0.0 mi" that reads as nothing.
            let yards = meters * 1.09361
            return "\(Int(yards.rounded())) yd"
        }
    }

    /// Average pace for display: "m:ss /km" (metric) or "m:ss /mi" (imperial). "—" when pace is undefined
    /// (nil or ≤ 0, i.e. no distance yet). `secPerKm` is the seconds-per-kilometre the GPS recorder
    /// publishes. Byte-identical to the Kotlin `UnitFormatter.paceFromSecPerKm`, and to the post-workout
    /// pace shown in the workout detail view. (#1195)
    static func paceFromSecPerKm(_ secPerKm: Double?, system: UnitSystem) -> String {
        guard let secPerKm, secPerKm > 0 else { return "—" }
        let (secs, label): (Double, String) = system == .imperial
            ? (secPerKm / milesPerKilometer, "/mi")
            : (secPerKm, "/km")
        let s = Int(secs.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60)) \(label)"
    }

    /// Format a distance given in KILOMETRES (e.g. the Workouts "Total Distance" sum), with one decimal
    /// and a unit label. Metric: "12.4 km". Imperial: "7.7 mi".
    static func distanceFromKilometers(_ km: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(km) + " km"
        case .imperial: return oneDecimal(kmToMiles(km)) + " mi"
        }
    }

    /// Unit label only, for sites that format the number separately. "km" / "mi".
    static func distanceUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "mi" : "km"
    }

    // MARK: Mass (stored kg)

    /// kg → pounds.
    static func kgToPounds(_ kg: Double) -> Double { kg * poundsPerKilogram }

    /// Format a mass given in KILOGRAMS with one decimal + unit. Metric: "74.5 kg". Imperial: "164.2 lb".
    static func massFromKilograms(_ kg: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:   return oneDecimal(kg) + " kg"
        case .imperial: return oneDecimal(kgToPounds(kg)) + " lb"
        }
    }

    /// Mass unit label only. "kg" / "lb".
    static func massUnit(_ system: UnitSystem) -> String {
        system == .imperial ? "lb" : "kg"
    }

    // MARK: Height (stored cm)

    /// cm → total inches.
    static func cmToInches(_ cm: Double) -> Double { cm / centimetersPerInch }

    /// Decompose a height in CENTIMETRES into whole feet + inches (inches rounded, carried into feet).
    static func cmToFeetInches(_ cm: Double) -> (feet: Int, inches: Int) {
        let totalInches = Int(cmToInches(cm).rounded())
        var feet = totalInches / 12
        var inches = totalInches % 12
        if inches == 12 { feet += 1; inches = 0 }   // rounding can push 11.5" → 12"
        return (feet, inches)
    }

    /// Format a height given in CENTIMETRES. Metric: "178 cm". Imperial: "5′ 10″".
    static func heightFromCentimeters(_ cm: Double, system: UnitSystem) -> String {
        switch system {
        case .metric:
            return "\(Int(cm.rounded())) cm"
        case .imperial:
            let (ft, inch) = cmToFeetInches(cm)
            // Prime/double-prime are the conventional ft/in glyphs and read cleanly at small sizes.
            return "\(ft)′ \(inch)″"
        }
    }

    // MARK: Temperature (stored °C — absolute)

    /// °C → °F: F = C * 9/5 + 32.
    static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }

    /// Format an ABSOLUTE temperature in CELSIUS. Metric: "33.4 °C". Imperial: "92.1 °F".
    static func temperatureFromCelsius(_ c: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(c, decimals) + " °C"
        case .fahrenheit: return decimalString(celsiusToFahrenheit(c), decimals) + " °F"
        }
    }

    /// °C delta → °F delta: a DIFFERENCE scales by 9/5 with NO +32 offset (the offset cancels between
    /// the two absolute temperatures a delta is made of). Exposed as a Double because callers that need
    /// locale-aware decimals — the illness-signal label formats through `AppLanguage.activeLocale` so a
    /// German reader sees "0,7" — have to do their own formatting and would otherwise inline the 9/5,
    /// scattering the one rule that must not drift.
    static func celsiusDeltaToFahrenheit(_ dc: Double) -> Double { dc * 9.0 / 5.0 }

    /// Format a temperature DEVIATION (a ±Δ°C, e.g. the skin-temp deviation pipeline). A delta scales by
    /// 9/5 but does NOT add the +32 offset — that would be wrong for a difference.
    static func temperatureDeltaFromCelsius(_ dc: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        switch unit {
        case .celsius:    return decimalString(dc, decimals) + " °C"
        case .fahrenheit: return decimalString(celsiusDeltaToFahrenheit(dc), decimals) + " °F"
        }
    }

    /// The skin-temperature phrase used by the illness-signal label — number AND unit chip, ready to
    /// interpolate into one `%@`.
    ///
    /// #111/#622: the field is BIMODAL. An imported night carries an ABSOLUTE wrist °C, a live one a
    /// signed DEVIATION from baseline, and they share a column — so the +32 offset belongs to only one
    /// of them, and the chip is "°F" for one and "Δ°F" for the other. Both come from `SkinTempDisplay`,
    /// the same authority the Today and Health tiles use.
    ///
    /// The NUMBER is formatted here rather than by `SkinTempDisplay.format` purely so it can honour
    /// [locale]: the banner formats through `AppLanguage.activeLocale`, and a German reader must see
    /// "0,7" where the package's plain `String(format:)` would give "0.7". Pass nil for POSIX decimals.
    static func skinTempSignalPhrase(_ value: Double, fahrenheit: Bool, locale: Locale?) -> String {
        let kind = SkinTempDisplay.kind(of: value)
        let shown: Double
        if fahrenheit {
            shown = kind == .absolute ? celsiusToFahrenheit(value) : celsiusDeltaToFahrenheit(value)
        } else {
            shown = value
        }
        let number = String(format: kind == .absolute ? "%.1f" : "%+.1f", locale: locale, shown)
        return number + " " + SkinTempDisplay.unitSymbol(kind: kind, fahrenheit: fahrenheit)
    }

    /// Temperature unit label only. "°C" / "°F".
    static func temperatureUnit(_ unit: TemperatureUnit) -> String {
        unit == .fahrenheit ? "°F" : "°C"
    }

    // MARK: Effort scale (stored 0–100 — #268)

    /// NOOP stores Effort 0–100 (StrainScorer.maxStrain = 100). WHOOP's Day Strain axis is 0–21, and
    /// the import boundary rescales by 100/21 (WhoopExportImporter.dayStrainToEffortScale), so the exact
    /// inverse for a display-only 0–100 → 0–21 conversion is ×21/100. Kept byte-identical to that factor
    /// and to the Android `UnitFormatter.EFFORT_SCALE_FACTOR`. A wrong factor is pinned by the formatter tests.
    static let effortScaleFactor = 21.0 / 100.0

    /// The stored 0–100 Effort value mapped onto the selected display scale (the raw number, no unit).
    static func effortValue(_ value: Double, scale: EffortScale) -> Double {
        scale == .whoop ? value * effortScaleFactor : value
    }

    /// Format a stored 0–100 Effort value for display on the selected scale, to one decimal — the single
    /// helper every Effort read-out (Today tile, Intelligence, Live, Trends, Workouts) routes through so
    /// the toggle reaches all of them at once. The stored value is unchanged; only the display converts.
    static func effortDisplay(_ value: Double, scale: EffortScale) -> String {
        oneDecimal(effortValue(value, scale: scale))
    }

    /// The "out of" denominator label for the selected Effort scale — "100" or "21". Used by the tile
    /// caption ("of 100"/"of 21"), the chart unit ("/ 100"/"/ 21") and the model-breakdown axis label.
    static func effortScaleMax(_ scale: EffortScale) -> String {
        scale == .whoop ? "21" : "100"
    }

    // MARK: Helpers

    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func decimalString(_ v: Double, _ decimals: Int) -> String {
        decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
    }
}
