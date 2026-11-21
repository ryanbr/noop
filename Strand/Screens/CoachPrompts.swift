import Foundation

/// The suggested questions offered when a Coach thread is empty (#1862).
///
/// Extracted from `CoachView` so the Today launcher sheet and the full screen offer the SAME four
/// prompts. Two hardcoded lists would have drifted the moment either was edited, and the launcher's
/// whole purpose is to be a shortcut into the screen rather than a second, subtly different Coach.
///
/// The strings are unchanged and keep their existing String Catalog keys, so nothing needs retranslating.
enum CoachPrompts {
    static let suggestions: [String] = [
        String(localized: "How's my charge trending?"),
        String(localized: "What should today's training look like?"),
        String(localized: "Analyse my sleep"),
        String(localized: "Why am I run down?"),
    ]

    /// Display text for a chip that comes from an English-only list: `CoachSuggestions` (StrandAnalytics)
    /// and `AICoachEngine.followUpSuggestions` stay English because they are byte-identical to their
    /// Android twins, so they are looked up in the String Catalog only here, at display time. The
    /// localized text is also what a tap sends, so the coach is asked in the user's own language.
    static func localized(_ prompt: String) -> String {
        Bundle.main.localizedString(forKey: prompt, value: prompt, table: nil)
    }
}
