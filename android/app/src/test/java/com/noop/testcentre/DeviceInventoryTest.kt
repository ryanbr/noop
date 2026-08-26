package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the paired-device inventory. Swift twin: `DeviceInventoryTests`.
 *
 * The block exists because the header above it reads the last-connected prefs rather than the registry,
 * so a two-strap install produced a log that never mentioned the second strap.
 */
class DeviceInventoryTest {

    // The same relTime the diagnostics use, inlined so the test is independent of that private helper.
    private val rel: (Long) -> String = { ms ->
        if (ms < 60_000L) "just now" else {
            val m = ms / 60_000L
            when {
                m < 60 -> "${m}m ago"
                m < 1440 -> "${m / 60}h ${m % 60}m ago"
                else -> "${m / 1440}d ago"
            }
        }
    }

    private fun row(id: String, status: String, seen: Long, model: String = "WHOOP 4.0",
                    fw: String? = null) =
        InventoryRow(id, "WHOOP", model, status, seen, fw)

    @Test
    fun `an empty registry says so rather than printing a bare header`() {
        assertEquals(listOf("Devices:     none registered"), deviceInventoryLines(emptyList(), null, 1000L, rel))
    }

    @Test
    fun `the active strap is marked and sorted first even when seen longest ago`() {
        // The whole point: the ACTIVE row is the one a reader wants first, and it is NOT necessarily the
        // most recently seen — switching straps leaves the old one with a fresher lastSeen.
        val now = 100_000L
        val lines = deviceInventoryLines(
            listOf(
                row("whoop-B", "paired", now - 600),
                row("my-whoop", "active", now - 11_400, model = "WHOOP 5.0 / MG"),
            ),
            activeId = "my-whoop", nowSec = now, relTime = rel,
        )
        assertEquals(
            listOf(
                "Devices:     2 registered (1 active, 1 paired, 0 archived)",
                "  device id=my-whoop status=ACTIVE brand=WHOOP model=WHOOP 5.0 / MG lastSeen=3h 10m ago fw=unknown",
                "  device id=whoop-B status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=10m ago fw=unknown",
            ),
            lines,
        )
    }

    @Test
    fun `a never-seen row reads never rather than a huge duration`() {
        val lines = deviceInventoryLines(listOf(row("whoop-C", "paired", 0L)), null, 100_000L, rel)
        assertEquals("  device id=whoop-C status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=never fw=unknown", lines[1])
    }

    @Test
    fun `counts split active paired and archived`() {
        val now = 100_000L
        val lines = deviceInventoryLines(
            listOf(
                row("a", "active", now - 60), row("b", "paired", now - 60),
                row("c", "archived", now - 60), row("d", "archived", now - 60),
            ),
            "a", now, rel,
        )
        assertEquals("Devices:     4 registered (1 active, 1 paired, 2 archived)", lines[0])
    }

    @Test
    fun `ties break on id so the order never depends on registry iteration`() {
        val now = 100_000L
        val lines = deviceInventoryLines(
            listOf(row("zzz", "paired", now - 60), row("aaa", "paired", now - 60)), null, now, rel,
        )
        assertEquals(listOf("aaa", "zzz"), lines.drop(1).map { it.substringAfter("id=").substringBefore(" ") })
    }
}
