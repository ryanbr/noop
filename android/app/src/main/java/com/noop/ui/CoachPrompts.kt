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

/**
 * A question handed over by the Today Coach launcher sheet, for [CoachScreen] to send once (#1862).
 *
 * Swift passes this on the shared `AICoachEngine`, which is an app-wide `EnvironmentObject`. Android has
 * no equivalent shared instance here: `CoachScreen` takes `viewModel()`, which is scoped to the nav
 * back-stack entry, so state set from Today would reach a different object. A process-scoped holder is
 * the smallest thing that actually crosses that boundary.
 *
 * `@Volatile` because it is written on the main thread and read by the screen's first composition.
 * Setting it performs NO network work by itself; the send still happens in the Coach screen, which owns
 * the consent and error surface.
 */
object CoachHandoff {
    @Volatile
    var pendingPrompt: String? = null

    /** Take the pending question and clear it, so a recomposition cannot send it twice. */
    fun consume(): String? {
        val p = pendingPrompt
        pendingPrompt = null
        return p
    }
}
