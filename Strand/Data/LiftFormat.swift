import Foundation

// Number and unit formatting for the Lift Log.
//
// WEIGHT IS ALWAYS STORED IN KILOGRAMS. Only display and typed input are converted, using the
// unit system the user already picked for the whole app (`UnitPrefs.systemKey`) — the Lift Log
// deliberately does not add a second weight-unit setting of its own, so a pounds user gets pounds
// here for free and never has two settings that can disagree.
//
// Conversion goes through ONE constant in BOTH directions (`UnitFormatter.poundsPerKilogram`), so a typed
// value round-trips: enter 225 lb, store 102.058… kg, read it back and it renders 225 lb again.
// Using the exact 0.45359237 for input while displaying with the rounded 2.20462 would drift the
// number by a tenth on the way back and make the log look like it had edited itself.

enum LiftFormat {

    // MARK: - Weight

    /// Convert a typed weight in the user's display unit to the kilograms that get stored.
    static func kilograms(fromDisplay value: Double, system: UnitSystem) -> Double {
        system == .imperial ? value / UnitFormatter.poundsPerKilogram : value
    }

    /// Convert stored kilograms to the user's display unit, as a number (not a string) so callers
    /// can put it straight into an editable text field.
    static func display(fromKilograms kg: Double, system: UnitSystem) -> Double {
        system == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg
    }

    /// A stored weight rendered for display with its unit: "60 kg", "132.5 lb".
    static func weight(_ kg: Double?, system: UnitSystem) -> String {
        guard let kg else { return "—" }
        return "\(trim(display(fromKilograms: kg, system: system))) \(UnitFormatter.massUnit(system))"
    }

    /// The bare unit label for a field suffix.
    static func weightUnit(_ system: UnitSystem) -> String { UnitFormatter.massUnit(system) }

    // MARK: - Numbers

    /// Drop a trailing ".0" so a whole number reads as one: 8.0 → "8", 7.5 → "7.5".
    ///
    /// Weights and RPE are both entered as decimals but are usually whole, and "8.0 × 10" in a
    /// summary line reads like a precision the user did not type.
    static func trim(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    /// Parse a typed number, accepting both "7.5" and the comma decimal separator "7,5" that most of
    /// NOOP's shipped locales use on their keyboards. Returns nil for anything else.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    // MARK: - Durations

    /// A rest period as "2:00" / "45s" — minutes and seconds, which is how rest is spoken about.
    static func duration(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
