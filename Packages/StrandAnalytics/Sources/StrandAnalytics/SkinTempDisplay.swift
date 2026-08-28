import Foundation

/// How to present the bimodal `skinTempDevC` / `skin_temp` field (#622).
///
/// CSV / Health imports store **absolute** wrist °C (~30–35). The live BLE pipeline stores a
/// **signed deviation** from the personal baseline (±°C, e.g. −0.1). Both land in the same column;
/// `VitalBands.isAbsoluteSkinTemp` (v ≥ 20) tells them apart. Deep timeline charts raw absolute
/// samples, so a Today/Health tile that only shows −0.1 without saying "vs baseline" looks broken.
///
/// Twin of `com.noop.analytics.SkinTempDisplay`. Pure — unit-tested. Localization of full titles
/// stays in the app layer; this package only supplies kind, unit symbol, and number formatting.
public enum SkinTempDisplay {

    public enum Kind: String, Sendable, Equatable {
        /// Absolute wrist temperature (°C scale, typically ~30–35 worn).
        case absolute
        /// Signed deviation from the personal nightly baseline (±°C).
        case deviation
    }

    public static func kind(of value: Double) -> Kind {
        VitalBands.isAbsoluteSkinTemp(value) ? .absolute : .deviation
    }

    /// The one kind a MIXED series must be reduced to before any aggregate is taken (#1705).
    ///
    /// A CSV import writes absolute °C and the computed pipeline writes a deviation, both into this
    /// same field, so one window can hold both. Formatting stays honest per value — `kind(of:)` is
    /// re-derived for each — but a min, max, mean or window-over-window delta drawn across both is
    /// arithmetic on two different scales, and it looks plausible: a handful of ~34 °C readings lift a
    /// should-be-near-zero deviation average past a full degree, and the mean is then itself below 20
    /// so it gets labelled Δ°C.
    ///
    /// The newest entry decides, matching what `VitalSignsSummary` already does for its sparkline —
    /// the reading the user is actually looking at sets the scale, and older entries of the other kind
    /// drop out rather than being converted, because converting needs a baseline that a fresh
    /// import-only install does not have.
    ///
    /// - Parameter values: the window's values, ascending by day.
    /// - Returns: the kind to keep, or nil for an empty window.
    public static func dominantKind(valuesAscendingByDay values: [Double]) -> Kind? {
        values.last.map(kind(of:))
    }

    /// Trailing unit chip: `"°C"` / `"°F"` for absolute, `"Δ°C"` / `"Δ°F"` for deviation.
    public static func unitSymbol(kind: Kind, fahrenheit: Bool) -> String {
        let base = fahrenheit ? "°F" : "°C"
        return kind == .absolute ? base : "Δ\(base)"
    }

    /// Format the **number only** (no unit suffix). Deviations are always signed (`+0.1` / `-0.1`);
    /// absolute readings are unsigned. Applies °F conversion when `fahrenheit` is true
    /// (full C→F for absolute, ×9/5 only for deviation).
    public static func numberString(
        _ value: Double,
        kind: Kind,
        fahrenheit: Bool,
        decimals: Int = 1
    ) -> String {
        let display: Double
        if fahrenheit {
            display = kind == .absolute
                ? (value * 9.0 / 5.0 + 32.0)
                : (value * 9.0 / 5.0)
        } else {
            display = value
        }
        if kind == .absolute {
            return String(format: "%.\(decimals)f", display)
        }
        return String(format: "%+.\(decimals)f", display)
    }

    /// Full `"34.2 °C"` / `"+0.1 Δ°C"` string for one-shot call sites (Today cards, explorers).
    public static func format(
        _ value: Double,
        fahrenheit: Bool,
        decimals: Int = 1
    ) -> String {
        let k = kind(of: value)
        let n = numberString(value, kind: k, fahrenheit: fahrenheit, decimals: decimals)
        return "\(n) \(unitSymbol(kind: k, fahrenheit: fahrenheit))"
    }
}
