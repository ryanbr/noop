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

    /// A resolved reading: the number to show and the scale it is on.
    public struct Reading: Sendable, Equatable {
        public let value: Double
        public let kind: Kind
        public init(value: Double, kind: Kind) { self.value = value; self.kind = kind }
    }

    /// Which of a night's two skin-temp numbers a surface should LEAD with (#1844), the pure form of the
    /// rule the Health tile has applied since #1665.
    ///
    /// The absolute wins whenever the night measured one, because a deviation with no anchor cannot be
    /// read — "+0.9" is a fever or a warm bedroom and nothing on a card says which. The deviation is the
    /// fallback, not the default, and keeps its Δ unit so it is never mistaken for a wrist temperature
    /// (#622).
    ///
    /// Two shapes make this more than a preference, both real rows:
    ///  - a night scored before `skinTempC` shipped (2026-08-27) has only a deviation, and keeps exactly
    ///    the display that shipped before until a scoring pass refills it;
    ///  - a CALIBRATING night is the reverse — the deviation is nil until the baseline is usable
    ///    (~4 nights) while the absolute is measured from night one, so those wearers otherwise see an
    ///    empty card with a real temperature sitting behind it.
    ///
    /// `prefer` is the user's Settings choice (#1846): `.absolute` — the default, a temperature — or
    /// `.deviation` for wearers who read the ±baseline move, which is the more sensitive illness signal. It
    /// picks which number is tried FIRST; the other is still the fallback, so choosing one never blanks a
    /// card whose night only measured the other, and the unit always names the scale actually shown.
    ///
    /// Both values must come from the SAME row; see `DailyMetric.lastSkinTempReadingDay`. Twin of the
    /// Kotlin `SkinTempDisplay.leadReading`.
    public static func leadReading(absC: Double?, devC: Double?, prefer: Kind = .absolute) -> Reading? {
        let first = prefer == .absolute ? absC : devC
        if let f = first { return Reading(value: f, kind: prefer) }
        let other = prefer == .absolute ? devC : absC
        let otherKind: Kind = prefer == .absolute ? .deviation : .absolute
        if let o = other { return Reading(value: o, kind: otherKind) }
        return nil
    }

    /// Formats whichever number `leadReading` chose, with the unit for THAT scale.
    public static func formatReading(_ reading: Reading, fahrenheit: Bool, decimals: Int = 1) -> String {
        let n = numberString(reading.value, kind: reading.kind, fahrenheit: fahrenheit, decimals: decimals)
        return "\(n) \(unitSymbol(kind: reading.kind, fahrenheit: fahrenheit))"
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
        let signed = String(format: "%+.\(decimals)f", display)
        // #1842: a deviation that ROUNDS to zero must not keep its sign. `%+` prints "-0.0" for anything
        // in (-0.05, 0), and "-0.0 Δ°C" on a card reads as a fault rather than as "no change from your
        // baseline" — which is what it means. Drop the sign only when the rounded value is zero; a real
        // -0.1 keeps it. Twin of the Kotlin numberString.
        if Double(signed.dropFirst()) == 0 { return String(signed.dropFirst()) }
        return signed
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
