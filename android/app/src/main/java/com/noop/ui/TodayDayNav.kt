package com.noop.ui

import kotlin.math.abs

// MARK: - Day navigation (#817) - chevron arrows + horizontal swipe, iOS parity
//
// `selectedDayOffset` is days-back-from-today (0 = today, 1 = yesterday, ...). The header chevrons and a
// horizontal swipe across the dashboard both move it: older increments the offset (no upper bound - you
// can browse arbitrarily far back), newer decrements it but is CLAMPED at 0 so a future day can never be
// selected. These pure helpers hold that clamp so it's covered by a JVM test and shared by both the
// arrow taps and the swipe handler, matching the iOS DayNavBar's `canGoNewer` / `selectedOffset +/- 1`.

/**
 * #860 item 1: the launch day-landing policy, as ONE pure decision so the rule can't drift between the
 * screen and its test and stays byte-identical to the iOS `TodayView.launchDayOffset` twin. A FRESH-PROCESS
 * launch ALWAYS lands on today (offset 0), even when today has no data yet and the only banked data is N days
 * back - that exact case is what stranded a calibrating user on an old day after an app update (the reporter's
 * case on v7.6.0). A non-fresh (in-session) call returns [savedOffset] UNCHANGED, so tabbing away to an old
 * day and coming back within the same process preserves the user-navigated day (#739/#614). [hasTodayData]
 * and [latestDataDayBack] are accepted so the signature documents the inputs the retired auto-land consumed,
 * but on a fresh launch they intentionally have NO effect - the old "land on the most recent data day"
 * behaviour (#605/#739) is retired. Mirror EXACTLY in Swift.
 */
@Suppress("UNUSED_PARAMETER")
internal fun launchDayOffset(
    isFreshLaunch: Boolean,
    savedOffset: Int,
    hasTodayData: Boolean,
    latestDataDayBack: Int,
): Int {
    // Fresh process: snap to today unconditionally. The data-shape inputs are deliberately ignored so a
    // calibrating user whose newest data is days back still opens on today, not on that old day.
    if (!isFreshLaunch) return savedOffset
    return 0
}

/** The offset for one step toward an OLDER day (previous). Unbounded above - history runs as far back as
 *  the data does. */
internal fun dayNavOlder(selectedOffset: Int): Int = selectedOffset + 1

/** The offset for one step toward a NEWER day (next), CLAMPED at 0 so a future day is never selectable. */
internal fun dayNavNewer(selectedOffset: Int): Int = (selectedOffset - 1).coerceAtLeast(0)

/** True when there IS a newer day to step to (i.e. we're not already on today). Gates the > chevron's
 *  enabled state, mirroring the iOS `canGoNewer`. */
internal fun dayNavCanGoNewer(selectedOffset: Int): Boolean = selectedOffset > 0

/** The minimum horizontal drag (px) that counts as a day-change swipe, so a small wobble during a
 *  vertical scroll doesn't flip the day. ~64dp at mdpi; the handler passes density-scaled px. */
internal const val DAY_NAV_SWIPE_THRESHOLD_DP: Float = 64f

/**
 * Resolve a completed horizontal swipe to the next [selectedDayOffset]. A drag whose total horizontal
 * travel doesn't clear [thresholdPx] returns the offset UNCHANGED (treated as a non-swipe). A rightward
 * swipe (positive [dragX], the natural "go back" / reveal-the-past gesture) steps to the OLDER day; a
 * leftward swipe steps to the NEWER day, clamped at today. Pure so the gesture mapping is unit-tested.
 */
internal fun dayNavSwipeTarget(selectedOffset: Int, dragX: Float, thresholdPx: Float): Int = when {
    abs(dragX) < thresholdPx -> selectedOffset
    dragX > 0f -> dayNavOlder(selectedOffset)
    else -> dayNavNewer(selectedOffset)
}
