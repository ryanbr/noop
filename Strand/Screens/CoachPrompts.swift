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
}
