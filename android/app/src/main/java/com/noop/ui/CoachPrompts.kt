package com.noop.ui

/**
 * The suggested questions offered when a Coach thread is empty (#1862).
 *
 * Extracted from [CoachScreen] so the Today launcher sheet and the full screen offer the SAME four
 * prompts. Swift twin: `CoachPrompts.suggestions`.
 *
 * The strings are unchanged from what the Coach screen already shipped. They are English literals here
 * exactly as they were there — localizing them is a separate change with its own four-locale cost, and
 * doing it inside a launcher PR would bury it.
 */
object CoachPrompts {
    val SUGGESTIONS: List<String> = listOf(
        "How's my recovery trending this week?",
        "Should I train hard or take it easy today?",
        "Why might my HRV be low lately?",
        "How can I improve my sleep?",
    )
}
