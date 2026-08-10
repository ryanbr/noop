import Foundation

/// Honest live-BLE capability set for a WHOOP strap that NOOP can actually drive **without** a CSV /
/// Health import.
///
/// Calibrated SpO₂ **%** is deliberately **excluded**: AnalyticsEngine nulls `spo2Pct` for every WHOOP
/// live path (see `Spo2ReTrace` — fabricating a % from raw ADC needs WHOOP's proprietary curve). The
/// registry used to advertise `spo2` on every paired WHOOP, which made an empty Blood Oxygen tile look
/// like a bug rather than import-only design (#548).
///
/// Steps are 5.0 / MG only over BLE (4.0 has no on-device step counter NOOP can read). Skin temp /
/// sleep / strain remain listed because NOOP does decode and score them on-device (skin temp as a
/// nightly ±°C deviation after baseline calibration; firmware layout dependent).
///
/// Twin of `com.noop.data.WhoopLiveCapabilities`. Pure — covered by `swift test`.
public enum WhoopLiveCapabilities {

    /// Core metrics every WHOOP generation can feed in NOOP over BLE (no calibrated SpO₂ %).
    public static let base: Set<Metric> = [.hr, .hrv, .skinTemp, .sleep, .strainLoad]

    /// True when the model label names a 5.0 or MG (wizard labels: "4.0", "5.0 MG", "WHOOP 5.0", …).
    public static func isFiveOrMG(model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("5") || m.contains("mg")
    }

    /// Capability set for a freshly paired WHOOP with the given model label.
    public static func metrics(forModel model: String) -> Set<Metric> {
        var caps = base
        if isFiveOrMG(model: model) { caps.insert(.steps) }
        return caps
    }

    /// Comma-joined, sorted encoding used in `pairedDevice.capabilities` (matches DeviceRegistryStore).
    public static func encoded(forModel model: String) -> String {
        metrics(forModel: model).map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Drop calibrated SpO₂ from a stored set — used when reading old registry rows that still list it.
    public static func withoutCalibratedSpo2(_ caps: Set<Metric>) -> Set<Metric> {
        caps.subtracting([.spo2])
    }

    /// SQL-safe rewrite of a comma-joined capabilities string: remove bare `spo2` tokens only.
    /// Does not touch other metrics. Empty result is preserved as empty (caller should not write that).
    public static func stripSpo2Token(fromEncoded encoded: String) -> String {
        encoded
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != Metric.spo2.rawValue }
            .joined(separator: ",")
    }
}
