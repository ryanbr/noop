import Foundation

// MARK: - Polar model identification + PMD stream capability catalog (clean-room, public facts)
//
// A Polar sensor advertises a stable BLE name of the form "Polar <MODEL> <serial>" (public — visible in
// any BLE scanner). This maps that name to the model and to the PMD measurement streams the model is
// DOCUMENTED to expose, so a future `PolarPMDSource` can pick the right measurement to request per device
// (PPI for HRV on the optical bands; ECG on the H10) instead of probing blindly. R-R for HRV also arrives
// on the standard HR service (0x180D) for every model — that path already ships — so a model with no PMD
// entry here is still a first-class HR/R-R source, just not a PMD one.
//
// Facts only: model names are public product identifiers; the per-model PMD stream sets are from
// docs/DEVICE_SUPPORT_ROADMAP.md §PMD (official polar-ble-sdk). No third-party code.
//
// HARDWARE-GATED: the capability sets below are what each model is documented to support; a real device
// should confirm them before any behaviour gates on them (same stance as the roadmap's PPI-flag caveat).
// Notably OH1 vs Verity Sense differ on the gyroscope — Verity Sense carries the 9-axis IMU, OH1 does not.

public enum PolarModel: String, Sendable, Equatable, CaseIterable {
    /// Chest strap: ECG + ACC over PMD, plus HR + R-R on the standard service. No optical (PPG/PPI).
    case h10
    /// Chest strap: HR + R-R on the standard service only (no PMD service).
    case h9
    /// Optical armband: PPG + PPI + ACC over PMD, plus HR. No ECG, no gyroscope.
    case oh1
    /// Optical armband (Verity Sense): PPG + PPI + ACC + GYRO over PMD, plus HR. No ECG.
    case veritySense
    /// A Polar device whose model we don't recognise. Still usable as a standard HR/R-R strap; PMD streams
    /// are unknown, so a source must GET_MEASUREMENT_SETTINGS rather than assume.
    case unknown

    /// The PMD measurement streams this model is documented to expose. Empty for HR-only models (H9) and
    /// for `.unknown` — never a guess; an empty set means "read R-R off the standard HR service, or probe".
    public var pmdStreams: Set<PolarPmdMeasurement> {
        switch self {
        case .h10:         return [.ecg, .acc]
        case .h9:          return []
        case .oh1:         return [.ppg, .ppi, .acc]
        case .veritySense: return [.ppg, .ppi, .acc, .gyro]
        case .unknown:     return []
        }
    }

    /// The PMD measurement NOOP would request for HRV on this model: `.ppi` (inter-beat interval) where the
    /// optical bands expose it, nil on the H10/H9 (their R-R comes off the standard HR service — no PMD
    /// needed) and on `.unknown`. Keeps the "one signal NOOP actually needs" choice in one place.
    public var hrvPmdStream: PolarPmdMeasurement? {
        pmdStreams.contains(.ppi) ? .ppi : nil
    }

    /// Identify the model from a peripheral's advertised name. Case-insensitive on the "Polar <MODEL>"
    /// prefix; a non-Polar or unrecognised name resolves to `.unknown` (never a wrong guess). "Polar Sense"
    /// is the Verity Sense's advertised name (it does NOT advertise "Verity").
    public static func from(advertisedName name: String?) -> PolarModel {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        let n = raw.lowercased()
        guard n.hasPrefix("polar ") else { return .unknown }
        // Anchor on the model token — the word right after "Polar " — NOT a substring of the whole name.
        // A `contains` would misidentify a device whose serial happened to carry a model token (e.g. a
        // "Polar OH1 H10…" serial matching h10). `hasPrefix` is also order-independent here.
        if n.hasPrefix("polar h10") { return .h10 }
        if n.hasPrefix("polar h9") { return .h9 }
        if n.hasPrefix("polar oh1") { return .oh1 }
        if n.hasPrefix("polar sense") { return .veritySense }
        return .unknown
    }

    /// Whether an advertised name belongs to a Polar sensor AT ALL — the public "Polar " name prefix.
    /// Distinct from ``from(advertisedName:)``, which returns `.unknown` for BOTH a non-Polar strap and an
    /// unrecognised Polar one; this separates "not a Polar device" from "a Polar device we can't name yet",
    /// so Polar-only diagnostics never fire for a Wahoo/Garmin strap. Case- and whitespace-insensitive.
    /// Works on either a live scan name or a stored `PairedDevice.model`, so a paired strap auto-detects
    /// without a live connection.
    public static func isPolar(advertisedName name: String?) -> Bool {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return n.hasPrefix("polar ")
    }

    /// Engineer-facing model label for the debug strap log (not localised). `.unknown` reads as
    /// "(unrecognised model)" so it composes into "Polar (unrecognised model)".
    public var displayLabel: String {
        switch self {
        case .h10:         return "H10"
        case .h9:          return "H9"
        case .oh1:         return "OH1"
        case .veritySense: return "Verity Sense"
        case .unknown:     return "(unrecognised model)"
        }
    }

    /// One-line PMD / HRV-route capability summary for the debug strap log — a pure restatement of
    /// ``pmdStreams`` / ``hrvPmdStream`` (no behaviour gates on it). Streams are ordered by their PMD type
    /// byte for a stable, protocol-natural order, e.g. "PMD ecg,acc; HRV via standard R-R" (H10) or
    /// "PMD ppg,acc,ppi,gyro; HRV via PMD PPI" (Verity Sense).
    public var pmdDebugSummary: String {
        let streams: String
        if pmdStreams.isEmpty {
            streams = (self == .unknown) ? "PMD unknown (probe)" : "no PMD service"
        } else {
            streams = "PMD " + pmdStreams.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: ",")
        }
        return "\(streams); \(hrvPmdStream == nil ? "HRV via standard R-R" : "HRV via PMD PPI")"
    }

    /// The full one-line identification for the debug strap log / Test Centre when a Polar strap is seen —
    /// e.g. "Polar H10 identified — PMD ecg,acc; HRV via standard R-R". Auto-detected from any advertised
    /// name, whether a live scan result or a stored `PairedDevice.model`. Returns `nil` for a non-Polar
    /// name, so a caller emits nothing at all for a Wahoo/Garmin strap. The caller adds its own tag prefix.
    public static func debugIdentification(advertisedName name: String?) -> String? {
        guard isPolar(advertisedName: name) else { return nil }
        let model = from(advertisedName: name)
        return "Polar \(model.displayLabel) identified — \(model.pmdDebugSummary)"
    }
}
