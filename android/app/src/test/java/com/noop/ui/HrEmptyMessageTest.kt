package com.noop.ui

import com.noop.R
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Today HR card's empty state (#863): WHICH line it shows, and that none of them names a cause the
 * card has not established.
 *
 * The old single line opened "Calibrating" and asserted "no heart rate banked yet today", neither of
 * which the branch checks. All it knows is that the active-strap-plus-imports union returned under two
 * 5-minute buckets, so the lines now describe the stored rows and stop there. The one-bucket case used
 * to take that same "no heart rate" line, where it was plainly false.
 */
class HrEmptyMessageTest {

    @Test fun aPastDayAlwaysGetsTheStepBackLine() {
        for (count in listOf(0, 1, 2, 500)) {
            assertEquals(
                "a past day's line never depends on the bucket count",
                R.string.today_hr_empty_selected_day,
                hrEmptyMessageRes(isToday = false, windowIsWholeDay = true, dayBucketCount = count),
            )
        }
    }

    @Test fun anEmptyDaySaysNothingIsStoredRatherThanWhy() {
        assertEquals(
            R.string.today_hr_none_today,
            hrEmptyMessageRes(isToday = true, windowIsWholeDay = true, dayBucketCount = 0),
        )
    }

    @Test fun oneStoredBlockIsNotReportedAsNoHeartRate() {
        assertEquals(
            R.string.today_hr_one_block,
            hrEmptyMessageRes(isToday = true, windowIsWholeDay = true, dayBucketCount = 1),
        )
    }

    @Test fun aNarrowWindowOverADrawableDaySaysSo() {
        assertEquals(
            R.string.today_hr_empty_window,
            hrEmptyMessageRes(isToday = true, windowIsWholeDay = false, dayBucketCount = 2),
        )
    }

    /**
     * The regression the DAY-count rule exists for: a rolling 1h window that excludes the day's single
     * stored block. Judged on the windowed subset this would read zero and claim the day holds nothing,
     * which is the same over-claim in a new place.
     */
    @Test fun aNarrowWindowCannotDowngradeTheDaysOneBlockToNothing() {
        assertEquals(
            R.string.today_hr_one_block,
            hrEmptyMessageRes(isToday = true, windowIsWholeDay = false, dayBucketCount = 1),
        )
        assertEquals(
            R.string.today_hr_none_today,
            hrEmptyMessageRes(isToday = true, windowIsWholeDay = false, dayBucketCount = 0),
        )
    }

    /**
     * Source tripwires. The Apple twin's selection sits in a SwiftUI computed property with no JVM
     * reach, and the superseded copy lives in resource files no Kotlin test touches, so both are
     * asserted from here, the suite that runs on every push.
     */
    @Test fun neitherPlatformStillNamesAnUncheckedCause() {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val root = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
            .firstOrNull { File(it, "Strand/Screens/TodayView.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
        fun source(path: String) = File(root, path).readText()

        val apple = source("Strand/Screens/TodayView.swift")
        assertTrue(
            "the Apple card must choose its empty-state heading through hrEmptyTitle",
            apple.contains("subtitle: hrEmptyTitle,"),
        )
        assertTrue(
            "the Apple heading must split the one-block case out of the empty case",
            apple.contains("if hrPoints.count == 1 { return String(localized: " +
                "\"One five-minute block of heart rate today\") }"),
        )
        assertFalse(
            "the Apple card must not claim the strap is calibrating",
            apple.contains("Calibrating, no heart rate banked yet today"),
        )

        // The call site is what makes the day-count rule real: the function cannot see which list it
        // was handed, so a switch to the windowed subset would pass every case above while putting the
        // over-claim straight back on screen.
        val todayScreen = source("android/app/src/main/java/com/noop/ui/TodayScreen.kt")
        assertTrue(
            "the card must judge the DAY's buckets, not the windowed subset",
            todayScreen.contains("dayBucketCount = buckets.size,"),
        )

        val defaults = source("android/app/src/main/res/values/strings.xml")
        assertFalse(
            "the superseded Android line must not come back",
            defaults.contains("today_hr_calibrating"),
        )
        for (key in listOf("today_hr_none_today", "today_hr_one_block")) {
            assertTrue("$key must exist in the default resources", defaults.contains("\"$key\""))
        }
    }
}
