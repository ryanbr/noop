package com.noop.testcentre

import android.content.Context
import com.noop.ui.NoopPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A readback with no stored frame says so, instead of printing no line at all.
 *
 * `alarm.lastReportedRaw` only started being banked with #1707 on 2026-08-28, so any readback taken
 * before that has an epoch and no frame. The export used to emit the frame line only when the frame
 * existed, which made the two causes indistinguishable from the outside: a reader could not tell a
 * readback that predates the capture from one whose write failed, and an absent line reads as "checked,
 * nothing wrong". A 2026-09-28 capture carrying a 2045 readback cost a trip through git history for
 * exactly that reason, which is the cost this pins shut.
 *
 * The epoch is what gates the block, so these cases are reached by writing `lastReportedEpoch` and
 * varying only whether the frame is present. Twin of the Swift branch in `DebugDataDiagnostics`.
 */
@RunWith(RobolectricTestRunner::class)
class AlarmReadbackFrameLineTest {

    private fun ctx(): Context = RuntimeEnvironment.getApplication()

    /** An arm plus a readback, with the frame set to [raw] or cleared when null. */
    private fun seedReadback(c: Context, raw: String?) {
        val now = System.currentTimeMillis()
        NoopPrefs.of(c).edit()
            .putLong("alarm.lastArmSentEpoch", now / 1000L + 3600L)
            .putLong("alarm.lastArmAt", now)
            .putLong("alarm.lastReportedEpoch", now / 1000L + 3600L)
            .putLong("alarm.lastReportedAt", now)
            .apply()
        NoopPrefs.of(c).edit().apply {
            if (raw == null) remove("alarm.lastReportedRaw") else putString("alarm.lastReportedRaw", raw)
        }.apply()
    }

    private fun frameLines(c: Context): List<String> =
        AndroidDiagnostics.alarmLines(c).filter { it.startsWith("Readback frame:") }

    @Test
    fun `a stored frame is printed verbatim`() {
        val c = ctx()
        seedReadback(c, "0a1b2c3d")
        assertEquals(listOf("Readback frame: 0a1b2c3d"), frameLines(c))
    }

    @Test
    fun `a readback with no stored frame still emits a line saying why`() {
        val c = ctx()
        seedReadback(c, null)
        val lines = frameLines(c)
        assertEquals("the absent frame must still produce exactly one line", 1, lines.size)
        val line = lines.single()
        assertTrue("it must name the pre-capture cause: $line", line.contains("predates the frame capture"))
        assertTrue("it must name the failed-write cause: $line", line.contains("write failed"))
    }

    /** A blank frame is as uninformative as an absent one, so it takes the same branch. */
    @Test
    fun `a blank stored frame is treated as not stored`() {
        val c = ctx()
        seedReadback(c, "   ")
        val line = frameLines(c).single()
        assertTrue("a blank frame must not be printed as if it were bytes: $line",
                   line.contains("not stored"))
    }

    /** With no readback at all the block reports that instead, and emits no frame line. */
    @Test
    fun `no readback emits no frame line`() {
        val c = ctx()
        val now = System.currentTimeMillis()
        NoopPrefs.of(c).edit()
            .putLong("alarm.lastArmSentEpoch", now / 1000L + 3600L)
            .putLong("alarm.lastArmAt", now)
            .remove("alarm.lastReportedEpoch")
            .remove("alarm.lastReportedRaw")
            .apply()
        assertTrue(frameLines(c).isEmpty())
        assertTrue("the no-readback case has its own line",
                   AndroidDiagnostics.alarmLines(c).any { it == "Strap reports: (no readback)" })
    }
}
